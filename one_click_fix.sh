#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
mkdir -p "$ROOT"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# --------- INPUT: Get v4 token ---------
TOKEN_FILE="${TOKEN_FILE:-/opt/ai-movie-platform/.tmdb_v4.txt}"

if [[ $# -ge 1 ]]; then
  # token passed as 1st arg
  RAW="$1"
else
  if [[ -f "$TOKEN_FILE" ]]; then
    RAW="$(cat "$TOKEN_FILE")"
  else
    say "Paste your TMDb v4 Read Access Token (single line, no quotes, no Bearer). End with ENTER:"
    read -r RAW
  fi
fi

# normalize
V4="$(printf '%s' "$RAW" | tr -d '\r' \
     | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
           -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
if [[ "$V4" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then V4="${BASH_REMATCH[1]}"; fi

# sanity
LEN=${#V4}
DOTS=$(awk -F. '{print NF-1}' <<<"$V4")
say "TMDb v4 token sanity"
echo "Length: $LEN (expected >= 300; many accounts ~1000+)"
echo "Prefix: $(printf '%s' "$V4" | head -c 5)..."
echo "Dots:   $DOTS (must be exactly 2)"

[[ "${V4:0:3}" != "eyJ" ]] && fail "Not a v4 JWT (must start with eyJ). Go to TMDb Settings → API → 'API Read Access Token (v4 auth)'."
[[ $DOTS -ne 2 ]] && fail "Invalid JWT shape — must have exactly 2 dots (header.payload.signature)."
[[ $LEN -lt 100 ]] && fail "Token too short (<100). This is NOT the v4 JWT. Copy the long Read Access Token again."

# quick TLS sanity (should not be 000; 200/301/4xx all fine)
say "TLS reachability"
curl -I https://api.themoviedb.org/ | head -n 1 || true

# live check with v4
say "Verify against TMDb /3/configuration (expect 200)"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${V4}" \
  https://api.themoviedb.org/3/configuration || echo "000")
echo "HTTP: $CODE"
[[ "$CODE" != "200" ]] && fail "TMDb returned $CODE — token wrong / revoked / wrong account. Re-copy 'API Read Access Token (v4 auth)'."

# persist token safely
printf '%s' "$V4" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# --------- Write .env (FULL REPLACE) ---------
say "Write .env (FULL REPLACE)"
cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata

HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

TMDB_API_KEY=${V4}

NEXT_PUBLIC_API_BASE_URL=/api
ENV

# --------- Write gateway config ---------
say "Write gateway/nginx.conf"
mkdir -p gateway
cat > gateway/nginx.conf <<'NGINX'
server {
  listen 80;
  server_name _;

  location = /healthz { default_type text/plain; return 200 "ok\n"; }

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://frontend:6100/;
  }

  location /api/ {
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_pass http://backend:9087/api/;
  }

  location /docs  { proxy_pass http://backend:9087/docs; }
  location /redoc { proxy_pass http://backend:9087/redoc; }
}
NGINX

# --------- Build / Up ---------
say "Build (if needed) & start"
docker compose -p "$PROJECT" build backend frontend worker >/dev/null || true
docker compose -p "$PROJECT" up -d db backend frontend gateway worker

# --------- Health checks ---------
say "Wait for backend health"
for i in {1..60}; do
  if curl -fsS http://127.0.0.1:9087/api/health >/dev/null 2>&1; then
    echo "Backend OK"
    break
  fi
  sleep 1
  [[ $i -eq 60 ]] && fail "Backend health failed"
done

say "Gateway quick checks"
curl -fsS http://127.0.0.1:9088/healthz | grep -q '^ok' || fail "Gateway /healthz failed"
curl -fsS http://127.0.0.1:9088/api/health | grep -q '{"ok":true}' || fail "Gateway -> backend /api/health failed"

# --------- Ingest & List ---------
say "Ingest trending"
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending >/dev/null || fail "Ingest failed"

say "List 3 movies"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || fail "List failed"

say "ALL DONE"
