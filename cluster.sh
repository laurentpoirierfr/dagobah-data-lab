#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster.sh — cluster minikube 3 nœuds du projet k8s (Podman rootful).
#
# Wrapper autour de start-minikube-podman.sh (rootful, pids, ingress-dns,
# cert-manager…). Ajoute :
#   - un profil dédié (k8s) et un domaine dédié (k8s.test) ;
#   - l'arrêt des autres profils minikube avant le lancement ;
#   - un DNS hôte par lien : ~k8s.test est routé vers ingress-dns via le bridge
#     podman du cluster (resolvectl), sans toucher à la config globale ;
#   - une vérification de bout en bout (nœuds, DNS, Ingress HTTP).
#
# Usage : ./cluster.sh <commande> [options du lanceur...]
# ---------------------------------------------------------------------------
set -euo pipefail

PROFILE="${PROFILE:-k8s}"
NODES="${NODES:-3}"
CPUS="${CPUS:-4}"                       # par nœud
MEMORY="${MEMORY:-8g}"                  # par nœud
DOMAIN="${DOMAIN:-k8s.test}"
K8S_VERSION="${K8S_VERSION:-stable}"
OTHER_PROFILES="${OTHER_PROFILES:-minikube}"   # arrêtés avant 'up' (vide = aucun)
LAUNCHER="${LAUNCHER:-$HOME/Community/bin/start-minikube-podman.sh}"
# Données persistantes : dossier hôte monté sur /mnt/k8s-data dans chaque nœud
# (bind mount posé à la création du cluster -> 'make recreate' si on le change).
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/data}"
NODE_DATA_DIR="/mnt/k8s-data"   # /data est réservé par minikube (bind de /var/data)

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi
info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}cluster.sh${C_RESET} — cluster minikube '$PROFILE' ($NODES nœuds, *.${DOMAIN})

Commandes :
  up          Arrête les autres profils, crée/démarre le cluster, configure le DNS, vérifie
  stop        Arrête le cluster (le DNS par lien disparaît avec le bridge)
  delete      Supprime le cluster
  status      État minikube + nœuds
  dns         (Re)configure le DNS hôte pour *.${DOMAIN} (sudo)
  dns-remove  Retire la configuration DNS du bridge (sudo)
  verify      Vérifie nœuds, DNS et Ingress
  dry-run     Affiche le plan sans rien lancer
  help        Cette aide

Les options supplémentaires sont transmises au lanceur (ex: --recreate, --yes).

Variables : PROFILE=$PROFILE NODES=$NODES CPUS=$CPUS MEMORY=$MEMORY DOMAIN=$DOMAIN
            K8S_VERSION=$K8S_VERSION OTHER_PROFILES="$OTHER_PROFILES"
            DATA_DIR=$DATA_DIR (monté sur $NODE_DATA_DIR)
            LAUNCHER=$LAUNCHER
EOF
}

launcher() {
  mkdir -p "$DATA_DIR/volumes"
  [[ -x "$LAUNCHER" ]] || die "Lanceur introuvable ou non exécutable : $LAUNCHER (variable LAUNCHER)"
  "$LAUNCHER" \
    --profile "$PROFILE" --nodes "$NODES" --cpus "$CPUS" --memory "$MEMORY" \
    --domain "$DOMAIN" --k8s-version "$K8S_VERSION" \
    --mount-string "$DATA_DIR:$NODE_DATA_DIR" \
    --no-host-dns --no-verify-dns \
    "$@"
}

kc() { kubectl --context "$PROFILE" "$@"; }

cluster_ip() { minikube -p "$PROFILE" ip 2>/dev/null; }

# Interface hôte par laquelle on joint le nœud (bridge podman en rootful).
bridge_dev() {
  local ip="$1"
  ip route get "$ip" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

profile_running() {
  minikube -p "$1" status --format '{{.Host}}' 2>/dev/null | head -1 | grep -qx Running
}

stop_other_profiles() {
  local p
  for p in $OTHER_PROFILES; do
    [[ "$p" == "$PROFILE" ]] && continue
    if profile_running "$p"; then
      info "Arrêt du profil '$p' (libère CPU/RAM et évite les conflits)..."
      minikube stop -p "$p" >/dev/null && ok "Profil '$p' arrêté."
    fi
  done
}

cmd_dns() {
  local ip dev
  ip="$(cluster_ip)" || die "Cluster '$PROFILE' arrêté : lance './cluster.sh up'."
  dev="$(bridge_dev "$ip")"
  [[ -n "$dev" ]] || die "Aucune route vers $ip."
  if [[ "$dev" != podman* ]]; then
    die "$ip est joint via '$dev' et non via un bridge podman : cluster rootless ? (voir README du lanceur, §5)"
  fi

  if resolvectl domain "$dev" 2>/dev/null | grep -q -- "~${DOMAIN}\b" \
     && resolvectl dns "$dev" 2>/dev/null | grep -qw -- "$ip"; then
    ok "DNS hôte déjà configuré : *.${DOMAIN} -> $ip (lien $dev)."
    return 0
  fi

  info "DNS hôte : *.${DOMAIN} -> $ip via le lien $dev (sudo resolvectl)..."
  sudo resolvectl dns "$dev" "$ip"
  sudo resolvectl domain "$dev" "~${DOMAIN}"
  sudo resolvectl default-route "$dev" false
  sudo resolvectl flush-caches
  ok "DNS hôte configuré (non persistant : refait à chaque 'up' ou via 'dns')."
}

cmd_dns_remove() {
  local ip dev
  ip="$(cluster_ip)" || { info "Cluster arrêté : le bridge et sa config DNS n'existent plus."; return 0; }
  dev="$(bridge_dev "$ip")"
  [[ "$dev" == podman* ]] || { warn "Pas de bridge podman pour $ip."; return 0; }
  sudo resolvectl revert "$dev"
  sudo resolvectl flush-caches
  ok "Configuration DNS retirée du lien $dev."
}

cmd_verify() {
  local ip fails=0
  ip="$(cluster_ip)" || die "Cluster '$PROFILE' arrêté."

  local ready
  ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)"
  if [[ "$ready" -eq "$NODES" ]]; then
    ok "Nœuds Ready : $ready/$NODES"
  else
    warn "Nœuds Ready : $ready/$NODES"; fails=$((fails + 1))
  fi

  local n missing=0
  for n in $(kc get nodes -o name 2>/dev/null | cut -d/ -f2); do
    minikube -p "$PROFILE" ssh -n "$n" -- test -d "$NODE_DATA_DIR/volumes" 2>/dev/null || { warn "Montage $NODE_DATA_DIR absent sur $n"; missing=1; }
  done
  if [[ "$missing" -eq 0 ]]; then ok "Données : $DATA_DIR monté sur $NODE_DATA_DIR (tous les nœuds)"; else fails=$((fails + 1)); fi

  local host="verify.${DOMAIN}"
  info "Ingress de test temporaire : $host"
  kc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cluster-verify
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: $host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cluster-verify-none
            port:
              number: 80
EOF
  trap 'kc delete ingress cluster-verify -n default --ignore-not-found >/dev/null 2>&1 || true' RETURN

  local got="" i
  for i in $(seq 1 20); do
    got="$(dig +short +time=2 +tries=1 "$host" @"$ip" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
    [[ "$got" == "$ip" ]] && break
    sleep 2
  done
  if [[ "$got" == "$ip" ]]; then ok "ingress-dns : $host -> $got"; else warn "ingress-dns : '${got:-vide}' (attendu $ip)"; fails=$((fails + 1)); fi

  got="$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ "$got" == "$ip" ]]; then ok "Résolution hôte (getent) : $host -> $got"; else warn "Résolution hôte : '${got:-vide}' (attendu $ip) — essaie './cluster.sh dns'"; fails=$((fails + 1)); fi

  # Le backend n'existe pas : ingress-nginx doit répondre 503. 000 = injoignable.
  local code=""
  for i in $(seq 1 15); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$host/" 2>/dev/null || true)"
    [[ "$code" == "503" ]] && break
    sleep 2
  done
  if [[ "$code" == "503" ]]; then ok "Ingress HTTP : http://$host/ -> 503 (contrôleur joignable)"; else warn "Ingress HTTP : code '$code' (attendu 503)"; fails=$((fails + 1)); fi

  if kc get clusterissuer dagobah-ca-issuer >/dev/null 2>&1; then
    ok "ClusterIssuer TLS : dagobah-ca-issuer"
  else
    warn "ClusterIssuer dagobah-ca-issuer absent"; fails=$((fails + 1))
  fi

  if [[ "$fails" -eq 0 ]]; then
    ok "Cluster '$PROFILE' opérationnel : https://<app>.${DOMAIN}"
  else
    die "$fails vérification(s) en échec."
  fi
}

cmd_up() {
  stop_other_profiles
  launcher "$@"
  kubectl config use-context "$PROFILE" >/dev/null
  # Stockage géré par local-path-provisioner (helmfile, StorageClass local-data) :
  # on retire le provisioner hostpath mono-nœud de minikube.
  minikube -p "$PROFILE" addons disable default-storageclass >/dev/null 2>&1 || true
  minikube -p "$PROFILE" addons disable storage-provisioner >/dev/null 2>&1 || true
  kc delete storageclass standard --ignore-not-found >/dev/null 2>&1 || true
  minikube profile "$PROFILE" >/dev/null 2>&1 || true
  echo
  cmd_dns
  cmd_verify
}

cmd_status() {
  minikube -p "$PROFILE" status || true
  echo
  kc get nodes -o wide 2>/dev/null || true
}

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    up)          cmd_up "$@" ;;
    stop)        minikube stop -p "$PROFILE" ;;
    delete)      launcher --delete "$@" ;;
    status)      cmd_status ;;
    dns)         cmd_dns ;;
    dns-remove)  cmd_dns_remove ;;
    verify)      cmd_verify ;;
    dry-run)     launcher --dry-run "$@" ;;
    help|-h|--help) usage ;;
    *)           usage >&2; die "Commande inconnue : $cmd" ;;
  esac
}

main "$@"
