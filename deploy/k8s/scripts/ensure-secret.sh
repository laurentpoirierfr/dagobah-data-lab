#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ensure-secret.sh — crée un Secret avec des valeurs générées, s'il n'existe pas.
# Utilisé en hook helmfile 'prepare' : idempotent, valeurs stables entre upgrades.
#
#   ensure-secret.sh CTX NS NAME key=GEN [key=GEN ...]
#
#   GEN : hex32            64 caractères hexadécimaux (openssl rand -hex 32)
#         hex16            32 caractères hexadécimaux (clé 128 bits)
#         pass             mot de passe aléatoire de 24 caractères
#         value:TEXTE      valeur fixe
#         bcrypt:USER:KEY  "USER:<hash bcrypt>" du mot de passe généré pour KEY
#                          (KEY doit être déclaré avant)
# ---------------------------------------------------------------------------
set -euo pipefail
CTX="${1:?contexte}"; NS="${2:?namespace}"; NAME="${3:?nom}"; shift 3
k() { kubectl --context "$CTX" "$@"; }

k get ns "$NS" >/dev/null 2>&1 || k create ns "$NS" >/dev/null
k -n "$NS" get secret "$NAME" >/dev/null 2>&1 && exit 0

declare -A vals
args=()
for kv in "$@"; do
  key="${kv%%=*}"; gen="${kv#*=}"
  case "$gen" in
    hex32)    v="$(openssl rand -hex 32)" ;;
    hex16)    v="$(openssl rand -hex 16)" ;;
    pass)     v="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)" ;;
    value:*)  v="${gen#value:}" ;;
    bcrypt:*) IFS=: read -r _ user ref <<< "$gen"
              [[ -n "${vals[$ref]:-}" ]] || { echo "bcrypt: clé '$ref' inconnue" >&2; exit 1; }
              hash="$(PW="${vals[$ref]}" python3 -c 'import bcrypt,os; print(bcrypt.hashpw(os.environ["PW"].encode(), bcrypt.gensalt(10)).decode())')"
              v="$user:$hash" ;;
    *) echo "générateur inconnu : $gen" >&2; exit 1 ;;
  esac
  vals[$key]="$v"
  args+=(--from-literal="$key=$v")
done
k -n "$NS" create secret generic "$NAME" "${args[@]}" >/dev/null
echo "secret $NS/$NAME créé"
