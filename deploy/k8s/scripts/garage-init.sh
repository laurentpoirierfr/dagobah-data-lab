#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# garage-init.sh — initialise Garage après 'helmfile apply' (idempotent).
#
#  1. Layout : un rôle par nœud Garage (zone = nœud Kubernetes, capacité CAPACITY).
#  2. Buckets + clés d'accès (BUCKETS="bucket:clé[:ns/secret] ...").
#  3. Secrets Kubernetes avec les clés (ACCESS_KEY_ID / ACCESS_SECRET_KEY).
#  4. Fichiers locaux .s3/credentials + .s3/config (aws cli, rclone…).
#
# Usage : scripts/garage-init.sh [contexte] [domaine]   (aussi lancé en hook postsync)
# ---------------------------------------------------------------------------
set -euo pipefail

CTX="${1:-${KUBE_CONTEXT:-k8s}}"
DOMAIN="${2:-${DOMAIN:-k8s.test}}"
NS="${GARAGE_NS:-garage}"
CAPACITY="${CAPACITY:-20G}"
# bucket:clé[:namespace/secret]
BUCKETS="${BUCKETS:-cnpg-backups:cnpg:databases/s3-cnpg projet:projet:garage/s3-projet risingwave:risingwave:risingwave/s3-risingwave quickwit:quickwit:quickwit/s3-quickwit}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
S3_DIR="${S3_DIR:-$PROJECT_DIR/.s3}"

info() { printf '\e[34m[info]\e[0m %s\n' "$*"; }
ok()   { printf '\e[32m[ ok ]\e[0m %s\n' "$*"; }
die()  { printf '\e[31m[err ]\e[0m %s\n' "$*" >&2; exit 1; }

k() { kubectl --context "$CTX" "$@"; }
g() { k -n "$NS" exec garage-0 -c garage -- /garage "$@" 2>/dev/null; }

info "Attente des pods Garage..."
k -n "$NS" rollout status statefulset/garage --timeout=300s >/dev/null || die "StatefulSet garage pas prêt."

# --------------------------------------------------------------------------- 1. layout
version="$(g layout show | awk -F': ' '/Current cluster layout version/ {print $2}')"
pending=0
while read -r id ip; do
  [[ -n "$id" ]] || continue
  node="$(k -n "$NS" get pods -o json | jq -r --arg ip "${ip%:*}" '.items[] | select(.status.podIP == $ip) | .spec.nodeName')"
  [[ -n "$node" ]] || die "Nœud k8s introuvable pour $ip."
  info "Rôle Garage : $id -> zone $node, capacité $CAPACITY"
  g layout assign -z "$node" -c "$CAPACITY" "$id" >/dev/null
  pending=1
done < <(g status | awk '/NO ROLE ASSIGNED/ && $1 ~ /^[0-9a-f]{16}$/ {print $1, ($2 ~ /:/ ? $2 : $3)}')

if [[ "$pending" == 1 ]]; then
  g layout apply --version "$((version + 1))" >/dev/null
  ok "Layout appliqué (version $((version + 1)))."
else
  ok "Layout déjà en place (version $version)."
fi

# --------------------------------------------------------------------------- 2-3. buckets, clés, secrets
mkdir -p "$S3_DIR"; chmod 700 "$S3_DIR"
creds="$S3_DIR/credentials"; : > "$creds"; chmod 600 "$creds"

for spec in $BUCKETS; do
  IFS=: read -r bucket key target <<< "$spec"

  g bucket info "$bucket" >/dev/null || { g bucket create "$bucket" >/dev/null; info "Bucket créé : $bucket"; }
  g key info "$key" >/dev/null       || { g key create "$key" >/dev/null;       info "Clé créée : $key"; }
  g bucket allow --read --write --owner "$bucket" --key "$key" >/dev/null

  key_id="$(g key info "$key" --key-id | tr -d '[:space:]')"
  secret="$(g key info "$key" --secret-key | tr -d '[:space:]')"
  [[ "$key_id" == GK* && -n "$secret" ]] || die "Impossible de lire la clé $key."

  if [[ -n "$target" ]]; then
    tns="${target%/*}"; tname="${target#*/}"
    k get ns "$tns" >/dev/null 2>&1 || k create ns "$tns" >/dev/null
    k -n "$tns" create secret generic "$tname" \
      --from-literal=ACCESS_KEY_ID="$key_id" \
      --from-literal=ACCESS_SECRET_KEY="$secret" \
      --from-literal=BUCKET="$bucket" \
      --from-literal=ENDPOINT="http://garage.$NS.svc:3900" \
      --from-literal=REGION=garage \
      --dry-run=client -o yaml | k apply -f - >/dev/null
  fi

  cat >> "$creds" <<EOF
[$key]
aws_access_key_id = $key_id
aws_secret_access_key = $secret

EOF
  ok "s3://$bucket  (clé $key = $key_id)${target:+  -> secret $target}"
done

# --------------------------------------------------------------------------- 4. config locale
cfg="$S3_DIR/config"
: > "$cfg"
for spec in $BUCKETS; do
  IFS=: read -r _ key _ <<< "$spec"
  cat >> "$cfg" <<EOF
[profile $key]
region = garage
endpoint_url = https://s3.$DOMAIN
ca_bundle = $PROJECT_DIR/certs/$CTX-ca.crt
s3 =
  addressing_style = path

EOF
done

ok "Identifiants locaux : $creds (+ $cfg)"
cat <<EOF

  Utilisation locale (aws cli) :
    export AWS_SHARED_CREDENTIALS_FILE=$creds AWS_CONFIG_FILE=$cfg
    aws --profile projet s3 ls s3://projet/

  Dans le cluster : endpoint http://garage.$NS.svc:3900, région 'garage', path-style.
EOF
