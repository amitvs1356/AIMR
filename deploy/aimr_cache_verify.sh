#!/usr/bin/env bash
set -euo pipefail

echo "[1] Gateway config test:"
docker compose exec -T gateway nginx -t >/dev/null
echo " - nginx syntax: OK"

echo "[2] Reload gateway:"
docker compose exec -T gateway nginx -s reload >/dev/null
echo " - reload signal sent"

echo "[3] Show active /static block:"
docker compose exec -T gateway sh -lc 'nginx -T | sed -n "/location \\/static\\//,/}/p"'

echo "[4] Probe a poster and verify cache headers:"
HDRS="$(curl -sSI http://127.0.0.1:9088/static/posters/AI_Rising.png | awk "/^(Cache-Control|Expires):/")"
echo "$HDRS"

CACHE_OK=0
echo "$HDRS" | grep -qi 'Cache-Control:.*max-age=604800' && CACHE_OK=1
echo "$HDRS" | grep -qi 'Cache-Control: public, max-age=604800' && CACHE_OK=2 || true
echo "$HDRS" | grep -qi '^Expires:' >/dev/null || CACHE_OK=99

if [[ $CACHE_OK -eq 2 ]]; then
  echo "[OK] 7d cache active (public, max-age=604800) and Expires present."
elif [[ $CACHE_OK -eq 1 ]]; then
  echo "[WARN] max-age is 604800 but missing explicit 'public'."
elif [[ $CACHE_OK -eq 99 ]]; then
  echo "[WARN] Cache-Control seen but no Expires header."
else
  echo "[FAIL] Expected cache headers not found."
  exit 1
fi
