#!/usr/bin/env bash
set -euo pipefail

# ========= User Input =========
# Pass your TMDb v4 token as: --tmdb-token 'eyJXXXXXXXX...'
TMDB_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmdb-token)
      TMDB_TOKEN="${2:-}"; shift 2;;
    *)
      echo "Unknown arg: $1"; exit 2;;
  esac
done

if [[ -z "${TMDB_TOKEN}" ]]; then
  echo "ERROR: Please run with --tmdb-token 'eyJxxxxxxxx...'"
  echo "Get it from: https://www.themoviedb.org/settings/api  (API Read Access Token v4)"
  exit 1
fi

# ========= Constants =========
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
GATEWAY_PORT=9088
BACKEND_PORT=9087

cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# ========= 1) .env FULL REPLACEMENT =========
say "Writing fresh .env (full replacement)"
cat > .env <<ENV
# ====== ENV (FULL) ======
APP_ENV=prod
TZ=Asia/Kolkata

# Host ports (avoid 80/443—already in use by other apps)
HOST_GATEWAY_PORT=${GATEWAY_PORT}
HOST_BACKEND_PORT=${BACKEND_PORT}

# Postgres
POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

# API keys (TMDb v4 Bearer token — long JWT starting with eyJ…)
TMDB_API_KEY=${TMDB_TOKEN}

# Frontend config (gateway proxies /api → backend)
NEXT_PUBLIC_API_BASE_URL=/api
ENV

# ========= 2) Nginx (gateway) FULL REPLACEMENT =========
say "Writing fresh gateway/nginx.conf (full replacement)"
mkdir -p gateway
cat > gateway/nginx.conf <<'NGX'
server {
  listen 80;
  server_name _;

  # Common proxy defaults
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Connection "";

  # Health endpoint (gateway)
  location = /healthz {
    default_type text/plain;
    return 200 "ok\n";
  }

  # Frontend (Next.js on 6100)
  location / {
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://frontend:6100/;
  }

  # Backend API (FastAPI on 9087)
  location /api/ {
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://backend:9087/api/;
  }

  location /docs  { proxy_pass http://backend:9087/docs; }
  location /redoc { proxy_pass http://backend:9087/redoc; }
}
NGX

# ========= 3) Open ports on host firewall (idempotent) =========
say "Opening firewall ports ${GATEWAY_PORT}/${BACKEND_PORT} (idempotent)"
ufw allow ${GATEWAY_PORT}/tcp || true
ufw allow ${BACKEND_PORT}/tcp || true

# ========= 4) Rebuild & start only what’s needed =========
say "Rebuild frontend + gateway (no-cache) & start all containers"
docker compose -p "$PROJECT" build --no-cache frontend gateway >/dev/null
docker compose -p "$PROJECT" up -d db backend frontend gateway worker

say "Containers status"
docker compose -p "$PROJECT" ps

# ========= 5) Wait for backend health =========
say "Waiting for backend health @ http://127.0.0.1:${BACKEND_PORT}/api/health"
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null; then
    echo "Backend OK"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && fail "Backend health timeout"
done

# ========= 6) Verify TMDb token inside container =========
say "Checking TMDb token length + prefix inside backend container"
LEN=$(docker compose -p "$PROJECT" exec backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c' | tr -d '\r\n ')
echo "Length: $LEN"
[[ "$LEN" -lt 100 ]] && fail "TMDb token looks too short. Must be the long v4 Bearer token (eyJ…, 100+ chars)."

PREFIX=$(docker compose -p "$PROJECT" exec backend bash -lc 'printenv TMDB_API_KEY | head -c 3')
[[ "$PREFIX" != "eyJ" ]] && echo "WARNING: token does not start with eyJ; ensure it's the v4 Bearer JWT."

say "TMDb connectivity check (should be HTTP 200)"
STATUS=$(docker compose -p "$PROJECT" exec backend bash -lc \
  'curl -s -o /dev/null -w "%{http_code}\n" https://api.themoviedb.org/3/configuration -H "Authorization: Bearer $TMDB_API_KEY"')
echo "TMDb /configuration HTTP: $STATUS"
[[ "$STATUS" != "200" ]] && fail "TMDb returned $STATUS (expected 200). Check that you pasted the EXACT v4 token."

# ========= 7) DB sanity (idempotent column ensure) =========
say "Ensure required columns exist (safe if already present)"
docker compose -p "$PROJECT" exec db bash -lc '
psql -U $POSTGRES_USER -d $POSTGRES_DB <<SQL
ALTER TABLE movies ADD COLUMN IF NOT EXISTS popularity    DOUBLE PRECISION;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_average  DOUBLE PRECISION;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_count    INTEGER;
SQL
' >/dev/null || true

# ========= 8) Ingest + list =========
say "Trigger trending ingest"
set +e
INGEST_CODE=$(curl -s -o /dev/null -w "%{http_code}\n" -X POST "http://127.0.0.1:${GATEWAY_PORT}/api/ingest/tmdb/trending")
set -e
echo "Ingest HTTP: $INGEST_CODE"
[[ "$INGEST_CODE" != "200" ]] && fail "Ingest failed (HTTP $INGEST_CODE). Check backend logs."

say "Sample list (limit=3)"
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/api/movies?limit=3" || echo "List failed"

# ========= 9) Final summary =========
say "All good! Open these:"
echo "Frontend (proxied) :  http://<server-ip>:${GATEWAY_PORT}/"
echo "API health         :  http://<server-ip>:${GATEWAY_PORT}/api/health"
echo "Movies list (3)    :  http://<server-ip>:${GATEWAY_PORT}/api/movies?limit=3"
echo "Docs               :  http://<server-ip>:${GATEWAY_PORT}/docs"
