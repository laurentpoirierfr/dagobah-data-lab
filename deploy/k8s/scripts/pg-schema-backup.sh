#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pg-schema-backup.sh — sauvegarde / restauration LOGIQUE d'un schéma PostgreSQL
# de pg-main vers Garage S3, et inversement (pg_dump / pg_restore, format custom).
#
#   pg-schema-backup.sh backup  DB SCHEMA                     -> s3://cnpg-backups/logical/DB/SCHEMA/<horodatage>.dump
#   pg-schema-backup.sh list    DB [SCHEMA]                   -> sauvegardes disponibles
#   pg-schema-backup.sh restore DB SCHEMA [FICHIER|latest] [--target-db DB2]
#
# Chaque opération est un Job Kubernetes éphémère (namespace databases) :
#   backup  : initContainer pg_dump -> volume emptyDir -> conteneur aws-cli (upload)
#   restore : initContainer aws-cli (download) -> volume emptyDir -> conteneur pg_restore
# Identifiants : secrets databases/pg-main-superuser (PostgreSQL) et databases/s3-cnpg (S3).
# ---------------------------------------------------------------------------
set -euo pipefail

CTX="${KUBE_CONTEXT:-k8s}"
NS="databases"
PG_HOST="${PG_HOST:-pg-main-rw.databases.svc}"
BUCKET="${BUCKET:-cnpg-backups}"
PREFIX="${PREFIX:-logical}"
S3_ENDPOINT="${S3_ENDPOINT:-http://garage.garage.svc:3900}"
PG_IMAGE="${PG_IMAGE:-postgres:17-alpine}"          # même version majeure que pg-main
AWS_IMAGE="${AWS_IMAGE:-amazon/aws-cli:2.40.1}"

k() { kubectl --context "$CTX" "$@"; }
die() { printf '\e[31m[err ]\e[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\e[34m[info]\e[0m %s\n' "$*"; }
ok() { printf '\e[32m[ ok ]\e[0m %s\n' "$*"; }

usage() { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# Environnement commun du conteneur aws-cli (Garage : région "garage", path-style,
# pas de checksum CRC en trailer — sinon "Invalid payload signature").
aws_env() {
  cat <<EOF
          env:
            - {name: AWS_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: s3-cnpg, key: ACCESS_KEY_ID}}}
            - {name: AWS_SECRET_ACCESS_KEY, valueFrom: {secretKeyRef: {name: s3-cnpg, key: ACCESS_SECRET_KEY}}}
            - {name: AWS_DEFAULT_REGION, value: garage}
            - {name: AWS_REQUEST_CHECKSUM_CALCULATION, value: when_required}
            - {name: AWS_RESPONSE_CHECKSUM_VALIDATION, value: when_required}
            - {name: AWS_EC2_METADATA_DISABLED, value: "true"}
EOF
}

pg_env() {
  cat <<EOF
          env:
            - {name: PGHOST, value: "$PG_HOST"}
            - {name: PGUSER, value: postgres}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: pg-main-superuser, key: password}}}
            - {name: PGSSLMODE, value: require}
EOF
}

# Lance un Job, attend sa fin, affiche les logs de tous les conteneurs, le supprime.
run_job() {
  local name="$1" manifest="$2"
  k -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  printf '%s\n' "$manifest" | k apply -f - >/dev/null
  if ! k -n "$NS" wait --for=condition=complete "job/$name" --timeout=600s >/dev/null 2>&1; then
    k -n "$NS" logs "job/$name" --all-containers --prefix 2>/dev/null | tail -30 >&2 || true
    k -n "$NS" delete job "$name" --ignore-not-found >/dev/null
    die "Job $name en échec."
  fi
  k -n "$NS" logs "job/$name" --all-containers 2>/dev/null
  k -n "$NS" delete job "$name" --ignore-not-found >/dev/null
}

cmd_backup() {
  local db="${1:?DB requis}" schema="${2:?SCHEMA requis}"
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local key="$PREFIX/$db/$schema/$ts.dump"
  local job="pg-backup-$(echo "$db-$schema" | tr '_' '-' | cut -c1-40)"
  info "Sauvegarde du schéma $db.$schema -> s3://$BUCKET/$key"
  run_job "$job" "$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $job, namespace: $NS, labels: {app: pg-schema-backup}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      volumes: [{name: work, emptyDir: {}}]
      initContainers:
        - name: pg-dump
          image: $PG_IMAGE
$(pg_env)
          volumeMounts: [{name: work, mountPath: /work}]
          command: [sh, -ec]
          args:
            - |
              psql -d "$db" -tAc "SELECT 1 FROM pg_namespace WHERE nspname = '$schema'" | grep -q 1 \
                || { echo "schéma $db.$schema introuvable"; exit 1; }
              pg_dump -d "$db" --schema="$schema" --format=custom --compress=6 --file=/work/dump
              echo "pg_dump : \$(du -h /work/dump | cut -f1)"
              pg_restore --list /work/dump | grep -c -E ' TABLE DATA ' | sed 's/^/tables avec données : /'
      containers:
        - name: upload
          image: $AWS_IMAGE
$(aws_env)
          volumeMounts: [{name: work, mountPath: /work}]
          command: [sh, -ec]
          args:
            - |
              aws --endpoint-url $S3_ENDPOINT s3 cp /work/dump s3://$BUCKET/$key --only-show-errors
              aws --endpoint-url $S3_ENDPOINT s3 ls s3://$BUCKET/$key
EOF
)"
  ok "Sauvegarde : s3://$BUCKET/$key"
}

cmd_list() {
  local db="${1:?DB requis}" schema="${2:-}"
  local job="pg-backup-list"
  run_job "$job" "$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $job, namespace: $NS, labels: {app: pg-schema-backup}}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: list
          image: $AWS_IMAGE
$(aws_env)
          command: [sh, -ec]
          args: ["aws --endpoint-url $S3_ENDPOINT s3 ls --recursive s3://$BUCKET/$PREFIX/$db/${schema:+$schema/} || true"]
EOF
)"
}

# Dernière sauvegarde d'un schéma (clé S3 complète).
latest_key() {
  local db="$1" schema="$2"
  cmd_list "$db" "$schema" | awk '/\.dump$/ {print $4}' | sort | tail -1
}

cmd_restore() {
  local db="${1:?DB requis}" schema="${2:?SCHEMA requis}" file="${3:-latest}" target_db=""
  shift 2; [[ $# -gt 0 && "$1" != --* ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-db) target_db="${2:?--target-db DB}"; shift 2 ;;
      *) die "Option inconnue : $1" ;;
    esac
  done
  target_db="${target_db:-$db}"
  local key
  if [[ "$file" == latest ]]; then
    key="$(latest_key "$db" "$schema")"
    [[ -n "$key" ]] || die "Aucune sauvegarde pour $db.$schema."
  elif [[ "$file" == "$PREFIX/"* ]]; then
    key="$file"
  else
    key="$PREFIX/$db/$schema/$file"
  fi
  local job="pg-restore-$(echo "$target_db-$schema" | tr '_' '-' | cut -c1-40)"
  info "Restauration s3://$BUCKET/$key -> base $target_db, schéma $schema (remplacé s'il existe)"
  run_job "$job" "$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $job, namespace: $NS, labels: {app: pg-schema-backup}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      volumes: [{name: work, emptyDir: {}}]
      initContainers:
        - name: download
          image: $AWS_IMAGE
$(aws_env)
          volumeMounts: [{name: work, mountPath: /work}]
          command: [sh, -ec]
          args: ["aws --endpoint-url $S3_ENDPOINT s3 cp s3://$BUCKET/$key /work/dump --only-show-errors && ls -la /work/dump"]
      containers:
        - name: pg-restore
          image: $PG_IMAGE
$(pg_env)
          volumeMounts: [{name: work, mountPath: /work}]
          command: [sh, -ec]
          args:
            - |
              psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$target_db'" | grep -q 1 \
                || psql -d postgres -c 'CREATE DATABASE "$target_db"'
              # Remplacement du schéma en UNE transaction (tout ou rien) : DROP + recréation.
              # En cas d'erreur, ROLLBACK -> le schéma d'origine reste intact.
              { echo 'DROP SCHEMA IF EXISTS "$schema" CASCADE;'; pg_restore --file=- /work/dump; } \
                | psql -d "$target_db" --single-transaction -v ON_ERROR_STOP=1 -q >/dev/null
              psql -d "$target_db" -tAc "SELECT 'tables restaurées : ' || count(*) FROM pg_tables WHERE schemaname = '$schema'"
EOF
)"
  ok "Restauration terminée : $target_db.$schema"
}

case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  list)    shift; cmd_list "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) usage ;;
esac
