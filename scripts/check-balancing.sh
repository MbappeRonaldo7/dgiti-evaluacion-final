#!/usr/bin/env bash
# Hace N peticiones al ALB y cuenta qué instancia respondió cada una.
# Uso: ./scripts/check-balancing.sh http://<alb-dns> 20
set -euo pipefail
URL="${1:?Falta la URL del ALB}"
N="${2:-20}"

for _ in $(seq 1 "$N"); do
  curl -s "$URL/" | python3 -c "import sys,json; d=json.load(sys.stdin)['served_by']; print(d['instance_id'], d['availability_zone'])"
done | sort | uniq -c
