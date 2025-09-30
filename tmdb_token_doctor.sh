#!/usr/bin/env bash
set -euo pipefail
[[ $# -lt 1 ]] && { echo "Usage: $0 '<v4 JWT eyJ...>'"; exit 2; }
RAW="$1"
TOK="$(printf '%s' "$RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\"//' -e 's/\"$//' -e "s/^'//" -e "s/'$//")"
if [[ "$TOK" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then TOK="${BASH_REMATCH[1]}"; fi
LEN=${#TOK}; DOTS=$(awk -F. '{print NF-1}' <<<"$TOK")
echo "Length: $LEN"; echo "Dots: $DOTS"; echo "Prefix: $(printf '%s' "$TOK" | head -c 5)..."
[[ "${TOK:0:3}" != "eyJ" ]] && { echo "Not v4 (must start eyJ)"; exit 1; }
[[ $DOTS -ne 2 ]] && { echo "Invalid JWT (needs 2 dots)"; exit 1; }
[[ $LEN -lt 100 ]] && { echo "Too short (<100). Likely truncated"; exit 1; }
CODE=$(curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}" \
  -H 'accept: application/json' -H "Authorization: Bearer ${TOK}" \
  https://api.themoviedb.org/3/configuration || true)
echo "TMDb /3/configuration => $CODE"
[[ "$CODE" != "200" ]] && { echo "Token rejected by TMDb"; exit 1; }
echo -n "$TOK" > .tmdb_v4_clean
echo "Saved: .tmdb_v4_clean"
