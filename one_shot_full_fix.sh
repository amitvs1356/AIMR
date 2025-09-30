#!/usr/bin/env bash
set -euo pipefail

# =======================
# CONFIG
# =======================
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
TMDB_PIN_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"   # आप चाहें तो env से override कर सकते हैं (export TMDB_IP_OVERRIDE=...)
MIN_V4_LEN=100

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

need(){
  command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"
}

normalize_token(){ # trims whitespace/quotes/Bearer
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  if [[ "$raw" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then raw="${BASH_REMATCH[1]}"; fi
  printf '%s' "$raw"
}

check_token_shape(){ # returns 0 if ok
  local tok="$1"
  local len="${#tok}"
  local dots; dots=$(awk -F. '{print NF-1}' <<<"$tok")
  echo "Length: $len"
  echo "Dots:   $dots (must be exactly 2)"
  echo "Prefix: $(printf '%s' "$tok" | head -c 5)..."
  [[ "${tok:0:3}" == "eyJ" ]] || { echo "Not v4 (must start eyJ)"; return 1; }
  [[ "$dots" -eq 2 ]] || { echo "Invalid JWT shape"; return 1; }
  [[ "$len" -ge $MIN_V4_LEN ]] || { echo "Too short (<$MIN_V4_LEN). Likely truncated"; return 1; }
  return 0
}

probe_tmdb_200(){
  # 200 => good token; 401/403 => bad token; 000 => connectivity problem
  local tok="$1"
  local code
  code=$(curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}" \
    -H 'accept: application/json' -H "Authorization: Bearer $tok" \
    https://api.themoviedb.org/3/configuration || true)
  echo "TMDb /3/configuration => $code"
  [[ "$code" == "200" ]]
}

backup_now(){
  local ts="$(date +%Y%m%d_%H%M%S)"
  tar -czf "/root/aimr_backup_${ts}.tar.gz" -C "$ROOT" . || true
  echo "Backup -> /root/aimr_backup_${ts}.tar.gz"
}

# =======================
# PRECHECKS
# =======================
need curl
need docker
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 required."

[[ -d "$ROOT" ]] || fail "Root not found: $ROOT"
cd "$ROOT"

say "Quick backup of current folder"
backup_now

# =======================
# HOST EGRESS CHECKS
# =======================
say "Host egress to TMDb (force IPv4)"
HOST_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" https://api.themoviedb.org/3 || true)
echo "Host -> TMDb /3 => $HOST_CODE (204/401 ok; 000 means blocked but we'll pin inside containers)"

# =======================
# docker-compose override for pin + restart-policy
# =======================
say "Write docker-compose.override.yml (extra_hosts + restart policies)"
cat > docker-compose.override.yml <<YAML
services:
  backend:
    restart: unless-stopped
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"
  worker:
    restart: unless-stopped
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"
  gateway:
    restart: unless-stopped
  frontend:
    restart: unless-stopped
  db:
    restart: unless-stopped
YAML

# =======================
# Gateway nginx.conf (safe, complete)
# =======================
say "Write safe gateway/nginx.conf"
mkdir -p gateway
cat > gateway/nginx.conf <<'NGX'
server {
  listen 80;
  server_name _;

  # health
  location = /healthz {
    default_type text/plain;
    return 200 "ok\n";
  }

  # frontend → Next.js
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

  # backend → FastAPI
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

  # optional docs passthroughs (if backend serves these)
  location /docs { proxy_pass http://backend:9087/docs; }
  location /redoc { proxy_pass http://backend:9087/redoc; }
}
NGX

# =======================
# Ensure .env exists and has baseline (token blank for now)
# =======================
say "Write .env baseline (will inject TMDB token after validation)"
if [[ ! -f .env ]]; then
  cat > .env <<'ENV'
APP_ENV=prod
TZ=Asia/Kolkata

HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087

POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123

# TMDb v4 token — will be filled by this script
TMDB_API_KEY=

NEXT_PUBLIC_API_BASE_URL=/api
ENV
fi

# =======================
# Bring up containers
# =======================
say "docker compose up (db, backend, frontend, gateway, worker)"
docker compose -p "$PROJECT" up -d db backend frontend gateway worker
docker compose -p "$PROJECT" ps

# =======================
# Pin runtime /etc/hosts inside backend & worker (defensive)
# =======================
say "Pin 'api.themoviedb.org' -> ${TMDB_PIN_IP} inside backend & worker (runtime too)"
for svc in backend worker; do
  docker compose -p "$PROJECT" exec -T "$svc" bash -lc "
    set -e
    tmp=\$(mktemp)
    grep -v -i 'api\\.themoviedb\\.org' /etc/hosts > \"\$tmp\" || true
    printf '%s\t%s\t# pinned by one_shot_full_fix\n' '${TMDB_PIN_IP}' 'api.themoviedb.org' > /etc/hosts
    cat \"\$tmp\" >> /etc/hosts; rm -f \"\$tmp\"
    echo '--- /etc/hosts (head) ---'; sed -n '1,8p' /etc/hosts
    echo '--- curl -4 /3 (no auth) ---'; curl -4 -s -o /dev/null -w '%{http_code}\n' https://api.themoviedb.org/3 || true
  " || true
done

# =======================
# Ask for REAL TMDb v4 token, validate & verify 200
# =======================
say "Enter your REAL TMDb v4 Read Access Token"
echo "How to find: https://www.themoviedb.org/ → profile (top-right) → Settings → API → 'API Read Access Token (v4 auth)'."
echo "Paste the token below (single line, NO quotes, NO 'Bearer '):"
TOK_RAW=""
read -r TOK_RAW || true
TOK="$(normalize_token "${TOK_RAW}")"

ATT=0
while true; do
  ATT=$((ATT+1))
  echo "--- Token sanity ---"
  if check_token_shape "$TOK"; then
    echo "--- Remote verify on host ---"
    if probe_tmdb_200 "$TOK"; then
      echo "✔ Token is valid (200)."
      break
    else
      echo "Token not accepted by TMDb (need 200)."
    fi
  fi
  if [[ $ATT -ge 3 ]]; then
    fail "Could not validate TMDb v4 token. Please copy the full token exactly as shown in TMDb Settings."
  fi
  echo -n "Paste REAL v4 token again: "
  read -r TOK
  TOK="$(normalize_token "$TOK")"
done

# Save token to .env
sed -i "s|^TMDB_API_KEY=.*|TMDB_API_KEY=${TOK}|" .env

# Reload backend to pickup .env
say "Reload backend to pick updated TMDB_API_KEY"
docker compose -p "$PROJECT" up -d backend

# Confirm inside container
say "Confirm token inside backend & /configuration 200"
docker compose -p "$PROJECT" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p "$PROJECT" exec -T backend bash -lc \
  'curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true'

# =======================
# Alembic: fix env.py safely + run migrations
# =======================
say "Patch Alembic env.py inside backend & run migrations"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
cd /app || cd .
if [ ! -f alembic.ini ]; then
  echo "alembic.ini missing in container /app — cannot migrate"; exit 1
fi
DB_URL="postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@db:5432/$POSTGRES_DB"
if grep -q "^sqlalchemy.url" alembic.ini; then
  sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
else
  printf "\nsqlalchemy.url = %s\n" "$DB_URL" >> alembic.ini
fi
python - << "PY"
from pathlib import Path
p = Path("alembic/env.py")
p.write_text("""from alembic import context
from sqlalchemy import create_engine, pool

config = context.config
target_metadata = None  # using raw SQL in versions

def run_migrations_offline():
    url = config.get_main_option('sqlalchemy.url')
    context.configure(url=url, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online():
    url = config.get_main_option('sqlalchemy.url')
    connectable = create_engine(url, poolclass=pool.NullPool)
    with connectable.connect() as connection:
        context.configure(connection=connection)
        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
""")
print("env.py replaced OK")
PY
alembic upgrade head || alembic stamp head
'

# =======================
# Health → Ingest → List
# =======================
say "Health (direct)";    curl -fsS http://127.0.0.1:9087/api/health && echo
say "Health (gateway)";   curl -fsS http://127.0.0.1:9088/healthz && echo

say "Ingest trending via gateway (expect 200 / {\"ok\":true})"
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending || true

say "List top 3 via gateway"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || true; echo

# =======================
# Bundle diagnostics
# =======================
say "Bundle diagnostics"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="diag_$TS"; mkdir -p "$OUT"
{ echo "# host egress $HOST_CODE" ; docker compose -p "$PROJECT" ps ; awk '{gsub(/TMDB_API_KEY=.*/,"TMDB_API_KEY=***MASKED***"); print}' .env; } > "$OUT/summary.txt" 2>&1
docker compose -p "$PROJECT" logs --tail=300 backend  > "$OUT/log_backend.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 gateway  > "$OUT/log_gateway.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 frontend > "$OUT/log_frontend.txt" 2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 worker   > "$OUT/log_worker.txt"   2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 db       > "$OUT/log_db.txt"       2>&1 || true
tar -czf "diagnostics_${TS}.tar.gz" "$OUT" && rm -rf "$OUT"
say "DONE → diagnostics_${TS}.tar.gz"
