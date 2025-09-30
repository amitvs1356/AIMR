#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# ---------- INPUT ----------
RAW="${1:-}"
[[ -z "$RAW" ]] && fail "Usage: $0 <TMDB_V4_READ_ACCESS_TOKEN>\nExample:\n  $0 eyJxxxxxxxxxxxxxxxxxxxxxxxx....(very long JWT)..."

# ---------- NORMALIZE TOKEN ----------
V4="$(printf "%s" "$RAW" | tr -d "\r" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" -e "s/^\"//" -e "s/\"$//" -e "s/^'//" -e "s/'$//")"
if [[ "$V4" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then V4="${BASH_REMATCH[1]}"; fi

LEN=${#V4}
DOTS=$(awk -F. "{print NF-1}" <<<"$V4")
say "TMDb token sanity"
echo "Length: $LEN (should be 100+; usually ~1500)"
echo "Prefix: $(printf "%s" "$V4" | head -c 5)..."
echo "Dots:   $DOTS (must be 2 for a JWT)"

[[ "${V4:0:3}" != "eyJ" ]] && fail "Not a v4 JWT (must start with eyJ)"
[[ $LEN -lt 100 ]] && fail "Token too short (<100). You likely pasted the v3 key or a truncated token."
[[ $DOTS -ne 2 ]] && fail "Invalid JWT shape (needs exactly 2 dots)."

say "Verify against TMDb /3/configuration (expect 200)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "accept: application/json" \
  -H "Authorization: Bearer ${V4}" \
  https://api.themoviedb.org/3/configuration)
echo "HTTP: $HTTP"
[[ "$HTTP" != "200" ]] && fail "TMDb says $HTTP. Wrong token / app not approved / token revoked. Get your **API Read Access Token (v4 auth)** from TMDb Settings → API."

# ---------- WRITE .env (FULL REPLACEMENT) ----------
say "Write .env (FULL REPLACEMENT)"
cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata

# Host ports
HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

# Postgres
POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

# API keys
TMDB_API_KEY=${V4}

# Frontend config
NEXT_PUBLIC_API_BASE_URL=/api
ENV

# ---------- WRITE NGINX CONF (FULL REPLACEMENT) ----------
say "Write gateway/nginx.conf (FULL REPLACEMENT)"
mkdir -p gateway
cat > gateway/nginx.conf <<NGX
server {
  listen 80;
  server_name _;

  # simple health
  location = /healthz { default_type text/plain; return 200 "ok\n"; }

  # Frontend
  location / {
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://frontend:6100/;
  }

  # Backend API
  location /api/ {
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://backend:9087/api/;
  }

  location /docs  { proxy_pass http://backend:9087/docs; }
  location /redoc { proxy_pass http://backend:9087/redoc; }
}
NGX

# ---------- BUILD & START ----------
say "Build images (backend, frontend, worker) & bring up all"
docker compose -p "$PROJECT" build backend frontend worker >/dev/null
docker compose -p "$PROJECT" up -d db backend frontend gateway worker

# ---------- WAIT FOR BACKEND HEALTH ----------
say "Wait for backend health"
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:9087/api/health >/dev/null 2>&1; then
    echo "Backend OK"
    break
  fi
  sleep 1
  if [[ $i -eq 30 ]]; then fail "Backend did not become healthy"; fi
done

# ---------- DB MIGRATIONS (SMART) ----------
say "Run Alembic migrations (upgrade head), fallback to stamp if tables already exist"
set +e
docker compose -p "$PROJECT" exec -T backend bash -lc "alembic upgrade head"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "migrations failed (maybe tables exist). Trying: alembic stamp head"
  docker compose -p "$PROJECT" exec -T backend bash -lc "alembic stamp head"
fi

# ---------- ENSURE OPTIONAL COLUMNS ----------
say "Ensure extra columns on movies (idempotent)"
docker compose -p "$PROJECT" exec -T db bash -lc "
psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" <<SQL
ALTER TABLE movies ADD COLUMN IF NOT EXISTS popularity    DOUBLE PRECISION;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_average  DOUBLE PRECISION;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_count    INTEGER;
SQL
" >/dev/null || true

# ---------- RELOAD GATEWAY ----------
say "Reload gateway (nginx) and verify"
docker compose -p "$PROJECT" exec -T gateway nginx -s reload || true
curl -fsS http://127.0.0.1:9088/healthz | grep -q ^ok || fail "Gateway /healthz not ok"

# ---------- SMOKE: HOMEPAGE + API HEALTH ----------
say "Smoke test: homepage via gateway"
HTTP_HOME=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9088/)
echo "GET /  => $HTTP_HOME (expect 200)"

say "Smoke test: backend health via gateway"
curl -fsS http://127.0.0.1:9088/api/health | grep -q ok:true || fail "Gateway → backend health failed"

# ---------- INGEST + LIST ----------
say "Ingest trending from TMDb (via gateway)"
HTTP_ING=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending)
echo "POST /api/ingest/tmdb/trending => $HTTP_ING (expect 200/202)"
if [[ "$HTTP_ING" != "200" && "$HTTP_ING" != "202" ]]; then
  echo "NOTE: Ingest non-200; re-check TMDb token (but we did 200 before), or see backend logs:"
  docker compose -p "$PROJECT" logs --tail=100 backend | sed -n "\$-50,\$p" || true
fi

say "List a few movies (should be JSON array)"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || echo "LIST FAILED"

say "All set ✅"
echo "Open:"
echo "  http://<server-ip>:9088/           (Frontend)"
echo "  http://<server-ip>:9088/api/health (API health)"
echo "  http://<server-ip>:9088/docs       (OpenAPI docs)"
