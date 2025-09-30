#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# ---------- USER INPUT ----------
TMDB_TOKEN_RAW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmdb-token) TMDB_TOKEN_RAW="${2:-}"; shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done
[[ -z "${TMDB_TOKEN_RAW}" ]] && fail "Pass your TMDb v4 token:\n  $0 --tmdb-token 'eyJxxxxxxxx...'"

# ---------- NORMALIZE TOKEN ----------
# 1) Strip CR + leading/trailing spaces
TMDB_TOKEN="$(printf "%s" "$TMDB_TOKEN_RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
# 2) Drop surrounding quotes if any
TMDB_TOKEN="$(printf "%s" "$TMDB_TOKEN" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
# 3) If given as "Bearer <token>", keep only the token
if [[ "$TMDB_TOKEN" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then
  TMDB_TOKEN="${BASH_REMATCH[1]}"
fi

# Quick sanity checks
[[ "${TMDB_TOKEN:0:3}" != "eyJ" ]] && fail "This doesn't look like a v4 Bearer token (must start with eyJ...)"
LEN=${#TMDB_TOKEN}
[[ $LEN -lt 100 ]] && fail "Token too short ($LEN). Likely v3 key or truncated value."

# ---------- .env (FULL REPLACEMENT) ----------
say "Writing fresh .env"
cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata

HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

# v4 Read Access Token (long eyJ… JWT) — NO quotes
TMDB_API_KEY=${TMDB_TOKEN}

# Frontend config
NEXT_PUBLIC_API_BASE_URL=/api
ENV

# ---------- gateway/nginx.conf (FULL REPLACEMENT) ----------
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

  location /        { proxy_pass http://frontend:6100/; }
  location /api/    { proxy_pass http://backend:9087/api/; }
  location /docs    { proxy_pass http://backend:9087/docs; }
  location /redoc   { proxy_pass http://backend:9087/redoc; }
}
NGX

# ---------- Rebuild & Start ----------
say "Rebuild & start services"
docker compose -p "$PROJECT" up -d --build

say "Wait for backend health"
for i in {1..40}; do
  if curl -fsS http://127.0.0.1:9087/api/health >/dev/null; then
    echo "Backend OK"
    break
  fi
  sleep 1
  [[ $i -eq 40 ]] && fail "Backend health failed"
done

say "Gateway checks"
curl -fsS http://127.0.0.1:9088/healthz >/dev/null || fail "Gateway /healthz failed"
curl -fsS http://127.0.0.1:9088/api/health >/dev/null || fail "Gateway → backend /api/health failed"

# ---------- Validate TMDb from INSIDE backend ----------
say "Validate TMDb token from inside backend"
docker compose -p "$PROJECT" exec backend bash -lc 'echo -n "Length: "; echo -n "$TMDB_API_KEY" | wc -c'

echo "-- /3/configuration (status + body) --"
docker compose -p "$PROJECT" exec backend bash -lc \
  'curl -sS -H "accept: application/json" -H "Authorization: Bearer $TMDB_API_KEY" -w "\n[HTTP %{http_code}]\n" https://api.themoviedb.org/3/configuration'

echo "-- /3/trending/movie/day (status + first 400 bytes) --"
docker compose -p "$PROJECT" exec backend bash -lc \
  'curl -sS -H "accept: application/json" -H "Authorization: Bearer $TMDB_API_KEY" -w "\n[HTTP %{http_code}]\n" https://api.themoviedb.org/3/trending/movie/day | head -c 400; echo'

STATUS=$(docker compose -p "$PROJECT" exec backend bash -lc \
  'curl -s -o /dev/null -H "accept: application/json" -H "Authorization: Bearer $TMDB_API_KEY" -w "%{http_code}" https://api.themoviedb.org/3/configuration')

if [[ "$STATUS" != "200" ]]; then
  cat <<'NOTE'

################################################################
TMDb 401/403 — common causes:
1) v3 key दिया (32-hex) — चाहिए v4 Read Access Token (eyJ… लंबा JWT)
2) token में quotes/newline/space — इस स्क्रिप्ट ने normalize कर दिया, फिर भी problem हो तो दोबारा कॉपी करें
3) गलत token कॉपी किया — जाएँ: https://www.themoviedb.org/settings/api
   "API Read Access Token (v4 auth)" कॉपी करें (बहुत लंबा eyJ…)
   .env में एक लाइन (बिना quotes):
     TMDB_API_KEY=eyJxxxxxxxxxxxxxxxxxxxxxxxx...
फिर:
   docker compose -p aimr up -d backend
   /opt/ai-movie-platform/full_replace_v4.sh --tmdb-token 'eyJ....'
################################################################
NOTE
  fail "TMDb validation failed (HTTP $STATUS)"
fi

say "TMDb OK. You can now ingest & list:"
echo "  curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending"
echo "  curl -fsS 'http://127.0.0.1:9088/api/movies?limit=3' | jq . || true"
