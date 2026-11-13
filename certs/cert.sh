#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# certs/cert.sh — certificats TLS du cluster minikube 'k8s' (cert-manager).
#
# - CA locale persistante : sauvegardée dans certs/ca/ et restaurée après chaque
#   (re)création du cluster -> la CA approuvée par le navigateur reste valide.
# - Émission de certificats (Certificate cert-manager) pour <host>.k8s.test,
#   wildcard inclus, export optionnel tls.crt/tls.key.
# - Approbation de la CA dans le magasin système et les navigateurs (NSS).
#
# Usage : certs/cert.sh <commande> [options]   (voir 'help')
# ---------------------------------------------------------------------------
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-k8s}"
DOMAIN="${DOMAIN:-k8s.test}"
ISSUER="${ISSUER:-dagobah-ca-issuer}"
CA_SECRET="${CA_SECRET:-dagobah-ca-secret}"
CA_NS="cert-manager"
CA_DIR="$CERTS_DIR/ca"                    # sauvegarde (clé privée !)
CA_PUB="$CERTS_DIR/$PROFILE-ca.crt"        # CA publique, à distribuer/approuver
ISSUED_DIR="$CERTS_DIR/issued"
TRUST_NAME="k8s-local-ca-$PROFILE"         # nom dans les magasins de confiance

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi
info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

kc() { kubectl --context "$PROFILE" "$@"; }

usage() {
  cat <<EOF
${C_BOLD}certs/cert.sh${C_RESET} — certificats TLS du cluster '$PROFILE' (*.${DOMAIN}, issuer $ISSUER)

CA locale :
  ca-backup            Sauvegarde la CA du cluster dans certs/ca/ (une fois)
  ca-restore           Réinstalle la CA sauvegardée dans le cluster et réémet les certificats
  ca-sync              ca-restore si une sauvegarde existe, sinon ca-backup (appelé par 'make up')
  ca-export            Écrit la CA publique dans $(basename "$CA_PUB")
  ca-info              Affiche la CA sauvegardée et celle du cluster
  trust                Approuve la CA : magasin système (sudo) + navigateurs NSS (Firefox, Chrome)
  untrust              Retire la CA des magasins de confiance

Certificats :
  create HOST [-n NS] [-s SECRET] [--export]
                       Émet un certificat (HOST court -> HOST.${DOMAIN} ; '*' -> *.${DOMAIN})
  export HOST [-n NS]  Écrit les fichiers depuis le secret k8s : certs/issued/<fqdn>/
                       tls.crt tls.key ca.crt fullchain.crt (HOST = nom d'hôte ou Certificate)
  export-all           Idem pour tous les certificats émis par $ISSUER
  show HOST [-n NS]    Détails du certificat (sujet, SAN, validité)
  check HOST           Vérifie le TLS servi par l'Ingress avec la CA locale
  list                 Certificats émis par $ISSUER (tous namespaces)
  delete HOST [-n NS]  Supprime le Certificate et son secret

Exemples :
  certs/cert.sh create monapp -n demo            # monapp.${DOMAIN}, secret monapp-tls
  certs/cert.sh create '*' -n demo --export       # wildcard *.${DOMAIN}
  certs/cert.sh export podinfo                    # certs/issued/podinfo.${DOMAIN}/
  certs/cert.sh export-all
  certs/cert.sh check podinfo                     # https://podinfo.${DOMAIN}

Variables : PROFILE=$PROFILE DOMAIN=$DOMAIN ISSUER=$ISSUER
EOF
}

# --------------------------------------------------------------------------- noms
fqdn() {
  local h="$1"
  case "$h" in
    "*")            echo "*.${DOMAIN}" ;;
    *."${DOMAIN}")  echo "$h" ;;
    *)              echo "${h}.${DOMAIN}" ;;
  esac
}
# Nom k8s du Certificate/secret : monapp.k8s.test -> monapp ; *.k8s.test -> wildcard-k8s-test
cert_name() {
  local f; f="$(fqdn "$1")"
  if [[ "$f" == "*."* ]]; then
    echo "wildcard-${DOMAIN//./-}"
  else
    local short="${f%."$DOMAIN"}"
    echo "${short//./-}"
  fi
}

parse_opts() {
  NS="${DEFAULT_NS:-}"; SECRET=""; EXPORT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NS="${2:?-n requiert un namespace}"; shift 2 ;;
      -s|--secret)    SECRET="${2:?-s requiert un nom}"; shift 2 ;;
      --export)       EXPORT=1; shift ;;
      *) die "Option inconnue : $1" ;;
    esac
  done
}

# --------------------------------------------------------------------------- CA
cluster_ca_crt() { kc -n "$CA_NS" get secret "$CA_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d; }
fingerprint() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

cmd_ca_backup() {
  kc -n "$CA_NS" get secret "$CA_SECRET" >/dev/null 2>&1 || die "Secret $CA_NS/$CA_SECRET introuvable (cluster démarré ?)."
  if [[ -f "$CA_DIR/tls.key" && "${FORCE:-0}" != 1 ]]; then
    die "Sauvegarde déjà présente dans $CA_DIR (FORCE=1 pour écraser)."
  fi
  mkdir -p "$CA_DIR"; chmod 700 "$CA_DIR"
  local k
  for k in tls.crt tls.key ca.crt; do
    kc -n "$CA_NS" get secret "$CA_SECRET" -o jsonpath="{.data.${k//./\\.}}" | base64 -d > "$CA_DIR/$k"
  done
  chmod 600 "$CA_DIR/tls.key"
  cmd_ca_export >/dev/null
  ok "CA sauvegardée dans $CA_DIR ($(fingerprint < "$CA_DIR/tls.crt"))"
  warn "certs/ca/tls.key est la clé privée de la CA : ne pas la committer ni la partager."
}

cmd_ca_restore() {
  [[ -f "$CA_DIR/tls.crt" && -f "$CA_DIR/tls.key" ]] || die "Aucune sauvegarde dans $CA_DIR (lancer ca-backup)."
  local want have
  want="$(fingerprint < "$CA_DIR/tls.crt")"
  have="$(cluster_ca_crt | fingerprint || true)"
  if [[ "$want" == "$have" ]]; then
    ok "CA du cluster déjà identique à la sauvegarde."
    cmd_ca_export >/dev/null
    return 0
  fi

  info "Restauration de la CA sauvegardée dans $CA_NS/$CA_SECRET..."
  # On garde les annotations cert-manager pour que le Certificate 'dagobah-ca'
  # considère le secret comme le sien et ne le régénère pas.
  kc -n "$CA_NS" create secret tls "$CA_SECRET" \
      --cert="$CA_DIR/tls.crt" --key="$CA_DIR/tls.key" --dry-run=client -o json \
    | jq --rawfile ca "$CA_DIR/ca.crt" '
        .data["ca.crt"] = ($ca | @base64)
        | .metadata.annotations = {
            "cert-manager.io/alt-names": "", "cert-manager.io/ip-sans": "", "cert-manager.io/uri-sans": "",
            "cert-manager.io/certificate-name": "dagobah-ca",
            "cert-manager.io/common-name": "dagobah-ca",
            "cert-manager.io/issuer-group": "cert-manager.io",
            "cert-manager.io/issuer-kind": "ClusterIssuer",
            "cert-manager.io/issuer-name": "dagobah-selfsigned" }
        | .metadata.labels = { "controller.cert-manager.io/fao": "true" }' \
    | kc apply -f - >/dev/null

  # Laisse cert-manager réévaluer, puis vérifie qu'il n'a pas régénéré la CA.
  sleep 5
  have="$(cluster_ca_crt | fingerprint || true)"
  [[ "$want" == "$have" ]] || die "cert-manager a régénéré la CA après restauration (attendu $want, obtenu $have)."
  ok "CA restaurée ($want)."

  reissue_all
  cmd_ca_export >/dev/null
}

# Réémet tous les certificats signés par l'issuer (leurs secrets portent l'ancienne CA).
reissue_all() {
  local rows ns name secret n=0
  rows="$(kc get certificate -A -o json | jq -r --arg i "$ISSUER" \
            '.items[] | select(.spec.issuerRef.name == $i) | "\(.metadata.namespace) \(.metadata.name) \(.spec.secretName)"')"
  [[ -n "$rows" ]] || { info "Aucun certificat à réémettre."; return 0; }
  while read -r ns name secret; do
    kc -n "$ns" delete secret "$secret" --ignore-not-found >/dev/null
    n=$((n + 1))
  done <<< "$rows"
  info "Réémission de $n certificat(s)..."
  while read -r ns name secret; do
    if kc -n "$ns" wait --for=condition=Ready "certificate/$name" --timeout=120s >/dev/null 2>&1; then
      ok "  $ns/$name"
    else
      warn "  $ns/$name pas prêt"
    fi
  done <<< "$rows"
}

cmd_ca_sync() {
  if [[ -f "$CA_DIR/tls.key" ]]; then cmd_ca_restore; else cmd_ca_backup; fi
}

cmd_ca_export() {
  if [[ -f "$CA_DIR/tls.crt" ]]; then
    cp "$CA_DIR/tls.crt" "$CA_PUB"
  else
    cluster_ca_crt > "$CA_PUB"
  fi
  [[ -s "$CA_PUB" ]] || die "Impossible d'obtenir la CA."
  ok "CA publique : $CA_PUB"
}

cmd_ca_info() {
  if [[ -f "$CA_DIR/tls.crt" ]]; then
    echo "${C_BOLD}Sauvegarde${C_RESET} ($CA_DIR/tls.crt)"
    openssl x509 -in "$CA_DIR/tls.crt" -noout -subject -enddate -fingerprint -sha256 | sed 's/^/  /'
  else
    echo "Sauvegarde : aucune"
  fi
  echo "${C_BOLD}Cluster${C_RESET} ($CA_NS/$CA_SECRET)"
  cluster_ca_crt | openssl x509 -noout -subject -enddate -fingerprint -sha256 2>/dev/null | sed 's/^/  /' \
    || echo "  indisponible"
}

# Rappel affiché après un export : sans la CA approuvée, le navigateur affiche
# "connexion non sécurisée" pour https://*.<domaine>.
browser_hint() {
  cat <<EOF

  ${C_YELLOW}Tests navigateur${C_RESET} : importer la CA ${C_BOLD}$CA_PUB${C_RESET}
  comme autorité de certification (pas le certificat du site) :
    - automatique : certs/cert.sh trust   (sudo + certutil/libnss3-tools)
    - Firefox     : Paramètres > Vie privée et sécurité > Certificats > Afficher les certificats
                    > Autorités > Importer… > cocher "Confirmer cette AC pour identifier des sites web"
    - Chrome      : chrome://settings/certificates > Autorités > Importer
  puis redémarrer le navigateur. Détails : docs « 08 — Certificats » (make docs-serve)
EOF
}

# --------------------------------------------------------------------------- confiance
nss_dbs() {
  local d
  for d in "$HOME/.pki/nssdb" \
           "$HOME"/.mozilla/firefox/*.default* \
           "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* \
           "$HOME"/snap/chromium/current/.pki/nssdb; do
    [[ -f "$d/cert9.db" ]] && echo "$d"
  done
  return 0
}

cmd_trust() {
  [[ -s "$CA_PUB" ]] || cmd_ca_export
  info "Magasin système : /usr/local/share/ca-certificates/$TRUST_NAME.crt (sudo)"
  sudo install -m 0644 "$CA_PUB" "/usr/local/share/ca-certificates/$TRUST_NAME.crt"
  sudo update-ca-certificates >/dev/null
  ok "CA approuvée par le système (curl, wget, openssl, Python, Go…)."

  if ! command -v certutil >/dev/null 2>&1; then
    warn "certutil absent : navigateurs non configurés (sudo apt install libnss3-tools, puis relancer 'trust')."
    return 0
  fi
  [[ -d "$HOME/.pki/nssdb" ]] || { mkdir -p "$HOME/.pki/nssdb"; certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password; }
  local db
  while read -r db; do
    certutil -d "sql:$db" -D -n "$TRUST_NAME" >/dev/null 2>&1 || true
    certutil -d "sql:$db" -A -t "C,," -n "$TRUST_NAME" -i "$CA_PUB"
    ok "CA approuvée dans NSS : $db"
  done < <(nss_dbs)
  info "Redémarre le navigateur pour prendre en compte la CA."
}

cmd_untrust() {
  if [[ -f "/usr/local/share/ca-certificates/$TRUST_NAME.crt" ]]; then
    sudo rm -f "/usr/local/share/ca-certificates/$TRUST_NAME.crt"
    sudo update-ca-certificates --fresh >/dev/null
    ok "CA retirée du magasin système."
  fi
  if command -v certutil >/dev/null 2>&1; then
    local db
    while read -r db; do
      certutil -d "sql:$db" -D -n "$TRUST_NAME" >/dev/null 2>&1 && ok "CA retirée de NSS : $db" || true
    done < <(nss_dbs)
  fi
}

# --------------------------------------------------------------------------- certificats
cmd_create() {
  local host="${1:?create HOST requis}"; shift
  DEFAULT_NS=default parse_opts "$@"
  local f name; f="$(fqdn "$host")"; name="$(cert_name "$host")"
  [[ -n "$SECRET" ]] || SECRET="${name}-tls"

  kc get ns "$NS" >/dev/null 2>&1 || kc create ns "$NS" >/dev/null
  info "Certificate $NS/$name : $f (secret $SECRET, issuer $ISSUER)"
  kc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $name
  namespace: $NS
  labels:
    app.kubernetes.io/managed-by: cert.sh
spec:
  secretName: $SECRET
  commonName: "$f"
  dnsNames:
    - "$f"
  duration: 2160h       # 90 jours
  renewBefore: 360h     # renouvelé 15 jours avant
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: $ISSUER
    kind: ClusterIssuer
    group: cert-manager.io
EOF
  kc -n "$NS" wait --for=condition=Ready "certificate/$name" --timeout=120s >/dev/null \
    || die "Certificat non prêt : kubectl -n $NS describe certificate $name"
  ok "Certificat prêt : secret $NS/$SECRET"
  cat <<EOF

  Dans un Ingress :
    tls:
      - hosts: ["$f"]
        secretName: $SECRET

  Ou laisse cert-manager le créer via l'annotation :
    cert-manager.io/cluster-issuer: $ISSUER
EOF
  [[ "$EXPORT" == 1 ]] && cmd_export "$host" -n "$NS"
  return 0
}

# Trouve le(s) Certificate correspondant à HOST : dnsName exact (HOST ou
# HOST.<domaine>) ou nom du Certificate. Sortie : "ns name secret fqdn" par ligne.
find_certs() {
  local host="$1" ns="${2:-}" f; f="$(fqdn "$host")"
  local scope=(-A); [[ -n "$ns" ]] && scope=(-n "$ns")
  kc get certificate "${scope[@]}" -o json 2>/dev/null | jq -r --arg f "$f" --arg h "$host" '
    .items[]
    | select(((.spec.dnsNames // []) | index($f)) or .metadata.name == $h or .metadata.name == ($h + "-tls"))
    | "\(.metadata.namespace) \(.metadata.name) \(.spec.secretName) \((.spec.dnsNames // [.spec.commonName])[0])"'
}

# Un seul Certificate attendu ; sinon demande de préciser -n.
find_one() {
  local rows n
  rows="$(find_certs "$1" "${2:-}")"
  n="$(grep -c . <<< "$rows" || true)"
  [[ "$n" -ge 1 ]] || die "Aucun certificat pour '$1'${2:+ dans $2} (voir 'list')."
  [[ "$n" -eq 1 ]] || { echo "$rows" >&2; die "Plusieurs certificats pour '$1' : préciser -n NAMESPACE."; }
  echo "$rows"
}

cmd_export() {
  local host="${1:?export HOST requis}"; shift
  parse_opts "$@"
  local ns name secret f
  read -r ns name secret f < <(find_one "$host" "$NS")
  export_secret "$ns" "$secret" "$f"
  [[ -s "$CA_PUB" ]] || cmd_ca_export >/dev/null
  browser_hint
}

# Écrit les fichiers physiques depuis le secret TLS (créé par cert-manager).
export_secret() {
  local ns="$1" secret="$2" f="$3" dir k
  kc -n "$ns" get secret "$secret" >/dev/null 2>&1 || die "Secret $ns/$secret absent (certificat pas encore émis ?)."
  dir="$ISSUED_DIR/${f/\*/wildcard}"
  mkdir -p "$dir"; chmod 700 "$dir"
  for k in tls.crt tls.key ca.crt; do
    kc -n "$ns" get secret "$secret" -o jsonpath="{.data.${k//./\\.}}" | base64 -d > "$dir/$k"
  done
  chmod 600 "$dir/tls.key"; chmod 644 "$dir/tls.crt" "$dir/ca.crt"
  cat "$dir/tls.crt" "$dir/ca.crt" > "$dir/fullchain.crt"
  # Contrôle : la clé correspond au certificat et la chaîne est valide.
  if [[ "$(openssl x509 -in "$dir/tls.crt" -noout -pubkey | openssl sha256)" \
        != "$(openssl pkey -in "$dir/tls.key" -pubout | openssl sha256)" ]]; then
    die "tls.key ne correspond pas à tls.crt ($ns/$secret)."
  fi
  openssl verify -CAfile "$dir/ca.crt" "$dir/tls.crt" >/dev/null || warn "Chaîne non vérifiée pour $f."
  ok "$f  <-  $ns/$secret"
  printf '    %s/{tls.crt,tls.key,ca.crt,fullchain.crt}  (expire %s)\n' "$dir" \
    "$(openssl x509 -in "$dir/tls.crt" -noout -enddate | cut -d= -f2)"
}

# Exporte tous les certificats émis par l'issuer.
cmd_export_all() {
  local rows ns name secret f n=0
  rows="$(kc get certificate -A -o json | jq -r --arg i "$ISSUER" '
    .items[] | select(.spec.issuerRef.name == $i)
    | "\(.metadata.namespace) \(.metadata.name) \(.spec.secretName) \((.spec.dnsNames // [.spec.commonName])[0])"')"
  [[ -n "$rows" ]] || { info "Aucun certificat émis par $ISSUER."; return 0; }
  while read -r ns name secret f; do
    export_secret "$ns" "$secret" "$f"; n=$((n + 1))
  done <<< "$rows"
  ok "$n certificat(s) exporté(s) dans $ISSUED_DIR"
  [[ -s "$CA_PUB" ]] || cmd_ca_export >/dev/null
  browser_hint
}

cmd_show() {
  local host="${1:?show HOST requis}"; shift
  parse_opts "$@"
  local ns name secret f
  read -r ns name secret f < <(find_one "$host" "$NS")
  kc -n "$ns" get certificate "$name"
  kc -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -issuer -ext subjectAltName -startdate -enddate
}

cmd_check() {
  local host="${1:?check HOST requis}" f
  f="$(fqdn "$host")"
  [[ "$f" != "*."* ]] || die "check attend un hôte précis (pas un wildcard)."
  [[ -s "$CA_PUB" ]] || cmd_ca_export >/dev/null
  info "TLS servi par https://$f (vérifié avec $CA_PUB)"
  local out
  out="$(openssl s_client -connect "$f:443" -servername "$f" -CAfile "$CA_PUB" -verify_return_error </dev/null 2>&1)" \
    || { echo "$out" | grep -E "verify error|Verify return code|connect:" >&2; die "Vérification TLS échouée pour $f."; }
  echo "$out" | openssl x509 -noout -subject -issuer -enddate 2>/dev/null | sed 's/^/  /'
  ok "Chaîne valide : $(echo "$out" | grep -m1 'Verify return code')"
}

cmd_list() {
  kc get certificate -A -o json | jq -r --arg i "$ISSUER" '
    ["NAMESPACE","NAME","READY","SECRET","DNS","EXPIRE"],
    (.items[] | select(.spec.issuerRef.name == $i)
      | [.metadata.namespace, .metadata.name,
         ((.status.conditions // [])[] | select(.type == "Ready") | .status) // "?",
         .spec.secretName, (.spec.dnsNames // [] | join(",")), (.status.notAfter // "-")])
    | @tsv' | column -t
}

cmd_delete() {
  local host="${1:?delete HOST requis}"; shift
  parse_opts "$@"
  local ns name secret f
  read -r ns name secret f < <(find_one "$host" "$NS")
  kc -n "$ns" delete certificate "$name" --ignore-not-found
  kc -n "$ns" delete secret "$secret" --ignore-not-found
  rm -rf "${ISSUED_DIR:?}/${f/\*/wildcard}"
  ok "Supprimé : $ns/$name (+ fichiers exportés)"
}

main() {
  local cmd="${1:-help}"; [[ $# -gt 0 ]] && shift
  command -v jq >/dev/null || die "jq requis."
  case "$cmd" in
    ca-backup)  cmd_ca_backup ;;
    ca-restore) cmd_ca_restore ;;
    ca-sync)    cmd_ca_sync ;;
    ca-export)  cmd_ca_export; browser_hint ;;
    ca-info)    cmd_ca_info ;;
    trust)      cmd_trust ;;
    untrust)    cmd_untrust ;;
    create)     cmd_create "$@" ;;
    export)     cmd_export "$@" ;;
    export-all) cmd_export_all ;;
    show)       cmd_show "$@" ;;
    check)      cmd_check "$@" ;;
    list)       cmd_list ;;
    delete)     cmd_delete "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "Commande inconnue : $cmd" ;;
  esac
}

main "$@"
