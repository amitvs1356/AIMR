#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }

# --- A) Force IPv4 + stable DNS inside backend container ---
say "Force IPv4 preference + pin TMDb host inside backend"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
# Prefer IPv4
if grep -q "^#.*precedence ::ffff:0:0/96" /etc/gai.conf 2>/dev/null; then
  sed -i "s/^#\s*\(precedence ::ffff:0:0\/96\s\+100\)/\1/" /etc/gai.conf || true
fi
# Add resolver tweak (helps with split v4/v6)
grep -q "single-request-reopen" /etc/resolv.conf || echo "options single-request-reopen" >> /etc/resolv.conf || true
# Pin Akamai v4 that worked
grep -q "api.themoviedb.org" /etc/hosts || echo "65.9.112.49 api.themoviedb.org" >> /etc/hosts
# Verify (should be 204)
echo -n "curl /3 => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" https://api.themoviedb.org/3 || true
# Token check (should be 200)
echo -n "/3/configuration => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true
'

# --- B) Patch DB schema (idempotent) ---
say "Add missing columns to movies (if not present)"
docker compose -p "$PROJECT" exec -T db bash -lc '
psql -U "$POSTGRES_USER" "$POSTGRES_DB" <<SQL
ALTER TABLE movies ADD COLUMN IF NOT EXISTS popularity    DOUBLE PRECISION DEFAULT 0;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_average  DOUBLE PRECISION DEFAULT 0;
ALTER TABLE movies ADD COLUMN IF NOT EXISTS vote_count    INTEGER          DEFAULT 0;
-- Ensure NOT NULL defaults (optional but safe for app queries)
UPDATE movies SET popularity=COALESCE(popularity,0), vote_average=COALESCE(vote_average,0), vote_count=COALESCE(vote_count,0);
SQL
'

# --- C) Make gateway send ALL /api traffic to backend only (bypass worker) ---
say "Repoint gateway to backend only (bypass worker for now)"
cat > gateway/nginx.conf <<'NGX'
worker_processes 1;
events { worker_connections 1024; }
http {
  sendfile on;
  upstream api_upstream {
    server backend:9087;  # only backend
  }
  server {
    listen 80;
    # Health
    location = /healthz { return 200 "ok\n"; }
    # API -> backend
    location /api/ {
      proxy_pass http://api_upstream;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
    }
    # Frontend (keep as is; serve whatever your frontend expects)
    location / {
      proxy_pass http://frontend:6100;
    }
  }
}
NGX

# Reload gateway (or restart if reload not available on alpine image)
docker compose -p "$PROJECT" exec -T gateway nginx -s reload || docker compose -p "$PROJECT" restart gateway

# --- D) Restart backend so it picks any env/network tweaks ---
say "Restart backend"
docker compose -p "$PROJECT" restart backend
sleep 3

# --- E) Quick tests through gateway ---
say "Gateway health"
curl -fsS http://127.0.0.1:9088/healthz && echo

say "Trigger ingest (now hits backend directly)"
ING=$(curl -s -o /tmp/ing.out -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending || true)
echo "Ingest => HTTP $ING"; head -c 400 /tmp/ing.out || true; echo

say "List movies (limit=3)"
curl -s "http://127.0.0.1:9088/api/movies?limit=3" | sed -e 's/},/},\n/g' || true
echo
