#!/usr/bin/env bash
set -euo pipefail

# ============================
# CONFIG you must set ONCE:
# 1) नीचे TOKEN= में अपना TMDb "API Read Access Token" (v4) PASTE करें.
#    यह वही लंबा JWT है जो आपके screenshot में "API Read Access Token" बॉक्स में दिख रहा है.
#    must start with eyJ and must have EXACTLY 2 dots, e.g. eyJxxxxx.yyyyyy.zzzzzz
# 2) कुछ भी quote/Bearer मत जोड़िए; बस raw token.
# ============================
TOKEN="PASTE_YOUR_REAL_V4_JWT_HERE"

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
TZ="${TZ:-Asia/Kolkata}"
HOST_GATEWAY_PORT="${HOST_GATEWAY_PORT:-9088}"
HOST_BACKEND_PORT="${HOST_BACKEND_PORT:-9087}"
DB_NAME="${POSTGRES_DB:-aimovie}"
DB_USER="${POSTGRES_USER:-aimovie}"
DB_PASS="${POSTGRES_PASSWORD:-aimovie_pass_123}"

# Akamai anycast IPv4 that worked in your tests
TMDB_PIN_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

mkdir -p "$ROOT"
cd "$ROOT"

# ---------- 0) Token normalize + sanity ----------
say "Validate TMDb v4 token (must be eyJ... with exactly TWO dots)"
RAW="$TOKEN"
TOK="$(printf '%s' "$RAW" | tr -d '\r' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
if [[ "$TOK" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then TOK="${BASH_REMATCH[1]}"; fi
LEN=${#TOK}; DOTS=$(awk -F. '{print NF-1}' <<<"$TOK")
echo "Length: $LEN"
echo "Dots:   $DOTS"
echo "Prefix: $(printf '%s' "$TOK" | head -c 5)..."
[[ "${TOK:0:3}" != "eyJ" ]] && fail "Not a v4 JWT (must start 'eyJ'). Open TMDb Settings → API → 'API Read Access Token' और वही paste करें."
[[ $DOTS -ne 2 ]] && fail "Invalid JWT shape — token में exactly 2 dots होने चाहिए (header.payload.signature)."
[[ $LEN -lt 100 ]] && fail "Token बहुत छोटा लग रहा है; TMDb v4 JWT आमतौर पर 300+ bytes होता है. पूरा कॉपी करें (कहीं कट तो नहीं गया?)."

echo -n "$TOK" > .tmdb_v4_clean

# ---------- 1) .env ----------
say "Write .env"
cat > .env <<ENV
APP_ENV=prod
TZ=$TZ

HOST_GATEWAY_PORT=$HOST_GATEWAY_PORT
HOST_BACKEND_PORT=$HOST_BACKEND_PORT

POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS

TMDB_API_KEY=$TOK

NEXT_PUBLIC_API_BASE_URL=/api
ENV

# ---------- 2) docker-compose.yml (with extra_hosts pin for TMDb) ----------
say "Write docker-compose.yml (with TMDb IPv4 pin for backend & worker)"
cat > docker-compose.yml <<YML
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 20
    volumes:
      - dbdata:/var/lib/postgresql/data

  backend:
    build: ./backend
    environment:
      - TZ=${TZ}
    env_file:
      - .env
    ports:
      - "${HOST_BACKEND_PORT}:9087"
    depends_on:
      db:
        condition: service_healthy
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"

  worker:
    build: ./backend
    command: bash -lc "python -m app.worker"
    environment:
      - TZ=${TZ}
    env_file:
      - .env
    depends_on:
      db:
        condition: service_healthy
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"

  frontend:
    build: ./frontend
    environment:
      - TZ=${TZ}
      - NEXT_PUBLIC_API_BASE_URL=/api
    depends_on:
      - backend

  gateway:
    image: nginx:alpine
    depends_on:
      - frontend
      - backend
    ports:
      - "${HOST_GATEWAY_PORT}:80"
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro

volumes:
  dbdata:
YML

# ---------- 3) nginx.conf (fixed; last time it was truncated) ----------
say "Write gateway/nginx.conf"
mkdir -p gateway
cat > gateway/nginx.conf <<NGINX
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

  location /docs  { proxy_pass http://backend:9087/docs;  }
  location /redoc { proxy_pass http://backend:9087/redoc; }
}
NGINX

# ---------- 4) Build + Up ----------
say "Build & Up"
docker compose -p "$PROJECT" build backend frontend
docker compose -p "$PROJECT" up -d db backend frontend gateway worker
docker compose -p "$PROJECT" ps

# ---------- 5) Backend: pin at runtime as well (survives until recreate) ----------
say "Pin api.themoviedb.org -> ${TMDB_PIN_IP} inside running containers"
docker compose -p "$PROJECT" exec backend sh -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts"
docker compose -p "$PROJECT" exec worker  sh -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts" || true

# ---------- 6) TMDb reachability & token 200 test ----------
say "Check TMDb reachability and token validity from inside backend"
docker compose -p "$PROJECT" exec backend sh -lc 'echo -n "$TMDB_API_KEY" | wc -c'
CODE_NOAUTH=$(docker compose -p "$PROJECT" exec backend sh -lc \
  'curl -4 -s -o /dev/null -w "%{http_code}" https://api.themoviedb.org/3' || true)
echo "GET /3 (no auth) => $CODE_NOAUTH (expected 204)"
CODE_AUTH=$(docker compose -p "$PROJECT" exec backend sh -lc \
  'curl -4 -s -o /dev/null -w "%{http_code}" -H "accept: application/json" -H "Authorization: Bearer $TMDB_API_KEY" https://api.themoviedb.org/3/configuration' || true)
echo "GET /3/configuration (auth) => $CODE_AUTH (expected 200)"
[[ "$CODE_NOAUTH" != "204" ]] && echo "WARN: no-auth code not 204 (but may vary)."
[[ "$CODE_AUTH" != "200" ]] && fail "TMDb ने token को reject किया (code $CODE_AUTH). Screenshot वाले v4 token को दोबारा EXACTLY paste करें."

# ---------- 7) Alembic fix: alembic.ini + env.py ----------
say "Patch alembic.ini DSN and replace env.py to safe variant"
docker compose -p "$PROJECT" exec -T backend sh -lc '
set -e
cd /app
# alembic.ini
if [ -f alembic.ini ]; then
  if grep -q "^sqlalchemy.url" alembic.ini; then
    sed -i "s|^sqlalchemy.url.*|sqlalchemy.url = postgresql+psycopg2://'${DB_USER}':'${DB_PASS}'@db:5432/'${DB_NAME}'|" alembic.ini
  else
    sed -i "s|^\[alembic\]$|[alembic]\nsqlalchemy.url = postgresql+psycopg2://'${DB_USER}':'${DB_PASS}'@db:5432/'${DB_NAME}'|" alembic.ini
  fi
else
  echo "alembic.ini not found"; exit 1
fi

# env.py — use create_engine with url from ini (avoids engine_from_config arg issues)
python - <<PY
from pathlib import Path
p = Path("alembic/env.py")
p.write_text("""from alembic import context
from sqlalchemy import create_engine, pool
from logging.config import fileConfig

config = context.config
target_metadata = None  # using raw SQL in versions

def run_migrations_offline():
    url = config.get_main_option("sqlalchemy.url")
    context.configure(url=url, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online():
    url = config.get_main_option("sqlalchemy.url")
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
print("env.py replaced")
PY

alembic upgrade head || alembic stamp head
'

# ---------- 8) Health + Ingest sample ----------
say "Health checks"
curl -fsS "http://127.0.0.1:${HOST_BACKEND_PORT}/api/health" && echo
curl -fsS "http://127.0.0.1:${HOST_GATEWAY_PORT}/healthz" && echo

say "Trigger TMDb trending ingest via gateway"
set +e
INGEST=$(curl -fsS -X POST "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/ingest/tmdb/trending" 2>&1)
RC=$?
set -e
echo "$INGEST"
[[ $RC -ne 0 ]] && echo "WARN: ingest call non-zero; check backend logs."

say "Fetch few movies"
set +e
curl -fsS "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/movies?limit=3" || true
set -e
echo

# ---------- 9) Mini-report ----------
say "Collect short diagnostics"
{
  echo "# compose ps"
  docker compose -p "$PROJECT" ps
  echo
  echo "# backend last 120 lines"
  docker compose -p "$PROJECT" logs --tail=120 backend
  echo
  echo "# gateway last 80 lines"
  docker compose -p "$PROJECT" logs --tail=80 gateway
} > FIX_REPORT.txt || true
echo "Report saved: $ROOT/FIX_REPORT.txt"

say "ALL DONE 🎉  — If something fails, open FIX_REPORT.txt और backend logs देखें."
