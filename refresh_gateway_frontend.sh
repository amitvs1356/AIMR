#!/usr/bin/env bash
set -e
PROJECT=aimr

echo "[1/4] Rebuild gateway+frontend (no-cache)…"
docker compose -p "$PROJECT" build --no-cache frontend gateway

echo "[2/4] Restart gateway+frontend…"
docker compose -p "$PROJECT" up -d frontend gateway

echo "[3/4] Show nginx default.conf…"
docker compose -p "$PROJECT" exec gateway sh -lc 'cat /etc/nginx/conf.d/default.conf'

echo "[4/4] Test homepage (via gateway)…"
curl -I http://127.0.0.1:9088/ | head -n 1 || true
