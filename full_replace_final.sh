#!/usr/bin/env bash
set -euo pipefail

# =============================== USER INPUT ===============================
# Prompt for REAL TMDb v4 "API Read Access Token" (eyJ... with EXACTLY 2 dots)
read -r -p $'Paste your TMDb v4 API Read Access Token (eyJ… with EXACTLY 2 dots): ' RAW_TOKEN

# =============================== CONSTANTS ===============================
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"

# Defaults (env se override kar sakte ho)
TZ="${TZ:-Asia/Kolkata}"
HOST_GATEWAY_PORT="${HOST_GATEWAY_PORT:-9088}"
HOST_BACKEND_PORT="${HOST_BACKEND_PORT:-9087}"
DB_NAME="${POSTGRES_DB:-aimovie}"
DB_USER="${POSTGRES_USER:-aimovie}"
DB_PASS="${POSTGRES_PASSWORD:-aimovie_pass_123}"

# Akamai IPv4 that worked in your tests
TMDB_PIN_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# =============================== TOKEN CHECKS ===============================
normalize_token(){
  local t="$1"
  t="$(printf '%s' "$t" | tr -d '\r' \
       | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  if [[ "$t" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then t="${BASH_REMATCH[1]}"; fi
  printf '%s' "$t"
}
count_dots(){ awk -F. '{print NF-1}' <<<"$1"; }

say "Validating TMDb v4 token format"
TOKEN="$(normalize_token "$RAW_TOKEN")"
[[ "${TOKEN:0:3}" == "eyJ" ]] || fail "Not v4 (must start with 'eyJ'). Please copy from TMDb Settings → API → API Read Access Token."
DOTS="$(count_dots "$TOKEN")"
[[ "$DOTS" -eq 2 ]] || fail "JWT must contain exactly TWO dots. Got $DOTS."
[[ "${#TOKEN}" -ge 100 ]] || fail "Token looks too short (<100). Likely truncated—copy with the copy icon."

# Quick live check (no auth -> 204 expected)
say "Host → TMDb reachability check (IPv4)"
HOST_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" https://api.themoviedb.org/3 || true)
echo "Host /3 => $HOST_CODE (204 is fine)."

# =============================== PREP FS ===============================
mkdir -p "$ROOT"/gateway
cd "$ROOT"

# =============================== .env ===============================
say "Writing .env"
cat > .env <<ENV
TZ=$TZ
POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS
TMDB_API_KEY=$TOKEN
ENV

# =============================== docker-compose.yml ===============================
say "Writing docker-compose.yml (pins api.themoviedb.org for backend+worker via extra_hosts)"
cat > docker-compose.yml <<YML
name: ${PROJECT}
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 20
    volumes:
      - dbdata:/var/lib/postgresql/data

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${HOST_BACKEND_PORT}:9087"
    # DO NOT override command; use image default
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"

  worker:
    build:
      context: ./backend
      dockerfile: Dockerfile
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    command: bash -lc 'python -m app.worker'
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    depends_on:
      - backend
    ports:
      - "6100:6100"

  gateway:
    image: nginx:alpine
    depends_on:
      - backend
      - frontend
    ports:
      - "${HOST_GATEWAY_PORT}:80"
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro

volumes:
  dbdata:
YML

# =============================== NGINX CONF ===============================
say "Writing gateway/nginx.conf"
cat > gateway/nginx.conf <<NGX
server {
  listen 80;
  server_name _;

  # health
  location = /healthz { default_type text/plain; return 200 "ok\n"; }

  # frontend → Next.js
  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
    proxy_read_timeout 60s; proxy_send_timeout 60s;
    proxy_pass http://frontend:6100/;
  }

  # backend → FastAPI
  location /api/ {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
    proxy_read_timeout 60s; proxy_send_timeout 60s;
    proxy_pass http://backend:9087/api/;
  }
}
NGX

# =============================== BUILD & UP ===============================
say "Docker build + up"
docker compose -p "${PROJECT}" up -d --build

say "Stack status"
docker compose -p "${PROJECT}" ps

# If backend is restarting, print logs and fail
BACK_STAT="$(docker compose -p "${PROJECT}" ps backend | awk 'NR==2{print $4$5$6$7$8}')"
if echo "$BACK_STAT" | grep -qi "Restarting"; then
  docker compose -p "${PROJECT}" logs --no-color --tail=200 backend || true
  fail "Backend is restarting. See logs above."
fi

# =============================== PIN INSIDE CONTAINERS (runtime /etc/hosts) ===============================
say "Pinning TMDb IP inside backend & worker (/etc/hosts)"
docker compose -p "${PROJECT}" exec -T backend bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts" || true
docker compose -p "${PROJECT}" exec -T worker  bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts" || true

# =============================== TOKEN LIVE TEST INSIDE BACKEND ===============================
say "Verifying token inside backend (expect 200)"
docker compose -p "${PROJECT}" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p "${PROJECT}" exec -T backend bash -lc 'curl -4 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration'

# =============================== HEALTH & INGEST ===============================
say "Health checks"
curl -fsS "http://127.0.0.1:${HOST_BACKEND_PORT}/api/health" && echo || true
curl -fsS "http://127.0.0.1:${HOST_GATEWAY_PORT}/healthz" && echo || true

say "Trigger TMDb trending ingest via gateway"
if curl -fsS -X POST "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/ingest/tmdb/trending" -o - | cat; then
  echo
else
  echo "Ingest call failed (see backend logs next)."
fi

say "Fetch first 3 movies via gateway"
if curl -fsS "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/movies?limit=3" | head -c 200 | cat; then
  echo
fi

# =============================== FINAL REPORT ===============================
say "Backend recent logs (tail)"
docker compose -p "${PROJECT}" logs --no-color --tail=80 backend || true

say "DONE ✅ — If any step failed above, see the error message and logs."
