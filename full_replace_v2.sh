#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# ===== USER INPUT =====
TMDB_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmdb-token) TMDB_TOKEN="${2:-}"; shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done
if [[ -z "${TMDB_TOKEN}" ]]; then
  fail "Pass your TMDb v4 token:\n  $0 --tmdb-token 'eyJxxxxxxxx...'"
fi

# ===== .env FULL REPLACE =====
say "Writing fresh .env"
cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata

HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

TMDB_API_KEY=${TMDB_TOKEN}

NEXT_PUBLIC_API_BASE_URL=/api
ENV

# ===== Nginx CONF =====
say "Writing gateway/nginx.conf"
mkdir -p gateway
cat > gateway/nginx.conf <<'NGX'
server {
  listen 80;
  server_name _;

  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Connection "";

  location = /healthz {
    default_type text/plain;
    return 200 "ok\n";
  }

  location / {
    proxy_pass http://frontend:6100/;
  }

  location /api/ {
    proxy_pass http://backend:9087/api/;
  }
}
NGX

# ===== Restart all =====
say "Restarting services"
docker compose -p "$PROJECT" up -d --build

# ===== Health check =====
say "Backend health"
for i in {1..20}; do
  if curl -fsS http://127.0.0.1:9087/api/health >/dev/null; then
    echo "Backend OK"
    break
  fi
  sleep 1
done

say "Check TMDb connectivity"
LEN=$(docker compose -p "$PROJECT" exec backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c' | tr -d '\r\n ')
echo "Length: $LEN"
STATUS=$(docker compose -p "$PROJECT" exec backend bash -lc \
  'curl -s -o /dev/null -w "%{http_code}\n" https://api.themoviedb.org/3/configuration -H "Authorization: Bearer $TMDB_API_KEY"')
echo "HTTP status: $STATUS"
[[ "$STATUS" != "200" ]] && fail "TMDb returned $STATUS"
