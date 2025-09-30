#!/usr/bin/env bash
set -euo pipefail
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

[[ -f .tmdb_v4_clean ]] || fail "Run tmdb_token_doctor.sh first (must produce .tmdb_v4_clean)"
TOKEN="$(cat .tmdb_v4_clean)"

echo "=== Sanity: live check (must be 200) ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  https://api.themoviedb.org/3/configuration)
[[ "$CODE" != "200" ]] && fail "TMDb /3/configuration => $CODE (fix token/account first)"

echo "=== Write .env (FULL REPLACE) ==="
cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata

HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

TMDB_API_KEY=${TOKEN}
NEXT_PUBLIC_API_BASE_URL=/api
ENV

echo "=== Rebuild & Restart ==="
docker compose -p "$PROJECT" build backend frontend
docker compose -p "$PROJECT" up -d backend frontend gateway worker

echo "=== Health checks ==="
curl -fsS http://127.0.0.1:9087/api/health >/dev/null || fail "backend health failed"
curl -fsS http://127.0.0.1:9088/api/health >/dev/null || fail "gateway->backend health failed"

echo "=== Ingest trending ==="
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending >/dev/null || fail "ingest endpoint failed"

echo "=== List 3 movies ==="
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || fail "list failed"

echo "=== DONE ==="
