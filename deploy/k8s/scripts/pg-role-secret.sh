#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pg-role-secret.sh — mot de passe d'un rôle PostgreSQL géré par CNPG.
#
#   pg-role-secret.sh CTX ROLE [NS_APP SECRET_APP]
#
# Crée databases/pg-main-role-<ROLE> ("_" remplacé par "-") (type basic-auth, lu par CNPG pour le rôle)
# avec un mot de passe aléatoire, puis le copie dans NS_APP/SECRET_APP pour
# l'application. Idempotent : le mot de passe n'est généré qu'une fois.
# ---------------------------------------------------------------------------
set -euo pipefail
CTX="${1:?contexte}"; ROLE="${2:?rôle}"; APP_NS="${3:-}"; APP_SECRET="${4:-}"
DB_NS="${DB_NS:-databases}"; SRC="pg-main-role-${ROLE//_/-}"   # nom k8s : "_" -> "-"
k() { kubectl --context "$CTX" "$@"; }

k get ns "$DB_NS" >/dev/null 2>&1 || k create ns "$DB_NS" >/dev/null
if ! k -n "$DB_NS" get secret "$SRC" >/dev/null 2>&1; then
  pw="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"
  k -n "$DB_NS" create secret generic "$SRC" --type=kubernetes.io/basic-auth \
    --from-literal=username="$ROLE" --from-literal=password="$pw" >/dev/null
  # Étiquette requise pour que CNPG recharge le rôle quand le secret change.
  k -n "$DB_NS" label secret "$SRC" cnpg.io/reload=true >/dev/null
  echo "secret $DB_NS/$SRC créé"
fi

if [[ -n "$APP_NS" && -n "$APP_SECRET" ]]; then
  pw="$(k -n "$DB_NS" get secret "$SRC" -o jsonpath='{.data.password}' | base64 -d)"
  k get ns "$APP_NS" >/dev/null 2>&1 || k create ns "$APP_NS" >/dev/null
  k -n "$APP_NS" create secret generic "$APP_SECRET" \
    --from-literal=username="$ROLE" --from-literal=password="$pw" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
fi
