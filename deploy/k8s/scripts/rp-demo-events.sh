#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rp-demo-events.sh — produit N événements JSON de démo dans un topic Redpanda.
#
#   rp-demo-events.sh CTX [N] [TOPIC]
#
# Événements : {"event_id","customer_id"(1-4),"event_type"(view|cart|purchase),
#               "amount","event_time"} — customer_id correspond aux clients CDC de pg-main/app.
# ---------------------------------------------------------------------------
set -euo pipefail
CTX="${1:-k8s}"; N="${2:-50}"; TOPIC="${3:-shop-events}"
types=(view view view cart purchase)

for ((i = 0; i < N; i++)); do
  t="${types[RANDOM % ${#types[@]}]}"
  c=$((RANDOM % 4 + 1))
  if [[ "$t" == purchase ]]; then a=$((RANDOM % 196 + 5)); else a=0; fi
  printf '{"event_id":"%s","customer_id":%d,"event_type":"%s","amount":%d,"event_time":"%s"}\n' \
    "$(cat /proc/sys/kernel/random/uuid)" "$c" "$t" "$a" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
done | kubectl --context "$CTX" -n redpanda exec -i redpanda-0 -c redpanda -- \
  rpk topic produce "$TOPIC" >/dev/null

echo "$N événements produits dans $TOPIC"
