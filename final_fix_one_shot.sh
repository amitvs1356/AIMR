#!/usr/bin/env bash
set -euo pipefail

# ===== If you already know your REAL v4 token, you can paste here.
# If you leave the placeholder, the script will ASK you interactively.
TMDB_V4_TOKEN='PASTE_FULL_v4_TOKEN_HERE'

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
TZ="${TZ:-Asia/Kolkata}"
HOST_GATEWAY_PORT="${HOST_GATEWAY_PORT:-9088}"
HOST_BACKEND_PORT="${HOST_BACKEND_PORT:-9087}"
DB_NAME="${POSTGRES_DB:-aimovie}"
DB_USER="${POSTGRES_USER:-aimovie}"
DB_PASS="${POSTGRES_PASSWORD:-aimovie_pass_123}"
TMDB_PIN_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"   # Akamai IPv4 that worked

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

mkdir -p "$ROOT" "$ROOT/gateway" "$ROOT/backend" "$ROOT/worker" "$ROOT/frontend"
cd "$ROOT"

# ---------- get/validate token ----------
normalize_token() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  if [[ "$raw" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then raw="${BASH_REMATCH[1]}"; fi
  printf '%s' "$raw"
}

valid_token() {
  local t="$1"
  [[ "$t" =~ ^eyJ ]] || return 1
  local dots; dots=$(awk -F. '{print NF-1}' <<<"$t")
  [[ "$dots" -eq 2 ]] || return 1
  [[ "${#t}" -ge 100 ]] || return 1
  return 0
}

if ! valid_token "$(normalize_token "$TMDB_V4_TOKEN")"; then
  echo "Paste your REAL TMDb v4 'API Read Access Token' (eyJ… with EXACTLY TWO dots)."
  echo "Open: https://www.themoviedb.org/settings/api  →  copy the full 'API Read Access Token'."
  read -r -p "Token: " INPUT || true
  TMDB_V4_TOKEN="$(normalize_token "$INPUT")"
fi

TMDB_V4_TOKEN="$(normalize_token "$TMDB_V4_TOKEN")"
valid_token "$TMDB_V4_TOKEN" || fail "Invalid v4 token. It must start with eyJ, contain exactly TWO dots, and be full length."

say "Token looks OK (len=${#TMDB_V4_TOKEN})."

# ---------- .env ----------
say "Writing .env"
cat > .env <<ENV
TZ=${TZ}
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
TMDB_API_KEY=${TMDB_V4_TOKEN}
ENV

# ---------- backend entrypoint (alembic + uvicorn) ----------
say "Writing backend/entrypoint.sh"
cat > backend/entrypoint.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DB_URL="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

# Ensure alembic.ini has sqlalchemy.url
if [ -f alembic.ini ]; then
  if grep -q '^sqlalchemy\.url' alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    echo "sqlalchemy.url = ${DB_URL}" >> alembic.ini
  fi
fi

# Ensure alembic/env.py uses create_engine
if [ -f alembic/env.py ]; then
python - <<'PY'
from pathlib import Path
p = Path("alembic/env.py")
p.write_text("""from alembic import context
from sqlalchemy import create_engine, pool
from logging.config import fileConfig

config = context.config
target_metadata = None  # raw SQL in versions

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
print("env.py written")
PY
fi

# Run migrations best-effort
if command -v alembic >/dev/null 2>&1; then
  alembic upgrade head || alembic stamp head || true
fi

# Start uvicorn
exec uvicorn app.main:app --host 0.0.0.0 --port 9087
SH
chmod +x backend/entrypoint.sh

# ---------- Minimal Dockerfiles (safe) ----------
say "Writing Dockerfiles"
cat > backend/Dockerfile <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app
ENTRYPOINT ["/app/entrypoint.sh"]
DOCKER

cat > worker/Dockerfile <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app
CMD ["bash","-lc","python -m app.worker"]
DOCKER

cat > frontend/Dockerfile <<'DOCKER'
FROM node:20-alpine
WORKDIR /app
COPY package.json /app/
RUN npm install || true
COPY . /app
RUN npm run build || true
CMD ["docker-entrypoint.sh","sh","-c","node server.js || npm start || npx next start -p 6100"]
DOCKER

# ---------- gateway nginx ----------
say "Writing gateway/nginx.conf"
cat > gateway/nginx.conf <<'NGX'
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
    proxy_read_timeout 60s; proxy_send_timeout 60s;
    proxy_pass http://frontend:6100/;
  }

  location /api/ {
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
    proxy_read_timeout 60s; proxy_send_timeout 60s;
    proxy_pass http://backend:9087/api/;
  }
}
NGX

# ---------- docker-compose (IPv4 pin + HTTP/1.1 for httpx) ----------
say "Writing docker-compose.yml"
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
      timeout: 3s
      retries: 10

  backend:
    image: aimr-backend
    build:
      context: ./backend
    env_file: .env
    environment:
      HTTPX_HTTP2: "0"           # disable HTTP/2 to avoid TLS resets
      PYTHONUNBUFFERED: "1"
    depends_on:
      db:
        condition: service_healthy
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"
    ports:
      - "${HOST_BACKEND_PORT}:9087"

  worker:
    image: aimr-worker
    build:
      context: ./worker
    env_file: .env
    environment:
      HTTPX_HTTP2: "0"
      PYTHONUNBUFFERED: "1"
    depends_on:
      db:
        condition: service_healthy
    extra_hosts:
      - "api.themoviedb.org:${TMDB_PIN_IP}"
    ports:
      - "9087"

  frontend:
    image: aimr-frontend
    build:
      context: ./frontend
    depends_on:
      - backend
    ports:
      - "6100:6100"

  gateway:
    image: nginx:alpine
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - frontend
      - backend
    ports:
      - "${HOST_GATEWAY_PORT}:80"
YML

# ---------- Build & Up ----------
say "Build & Up"
docker compose -p "$PROJECT" build --no-cache backend worker frontend
docker compose -p "$PROJECT" up -d

# ---------- Ensure /etc/hosts pin inside running containers ----------
say "Pin /etc/hosts (runtime confirm)"
docker compose -p "$PROJECT" exec -T backend bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts; head -n 5 /etc/hosts"
docker compose -p "$PROJECT" exec -T worker  bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_PIN_IP} api.themoviedb.org' >> /etc/hosts; head -n 5 /etc/hosts"

# ---------- Live TMDb checks ----------
say "TMDb checks (backend)"
docker compose -p "$PROJECT" exec -T backend bash -lc '
  echo -n "TMDB_API_KEY len: "; echo -n "$TMDB_API_KEY" | wc -c
  echo -n "/3/configuration => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true
  echo -n "/3/trending/movie/day => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" "https://api.themoviedb.org/3/trending/movie/day?language=en-US&page=1" || true
'

say "TMDb checks (worker)"
docker compose -p "$PROJECT" exec -T worker bash -lc '
  echo -n "TMDB_API_KEY len: "; echo -n "$TMDB_API_KEY" | wc -c
  echo -n "/3/configuration => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true
  echo -n "/3/trending/movie/day => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" "https://api.themoviedb.org/3/trending/movie/day?language=en-US&page=1" || true
'

# ---------- DB tables quick check ----------
say "DB tables (backend)"
docker compose -p "$PROJECT" exec -T backend bash -lc '
python - <<PY
import os
from sqlalchemy import create_engine, inspect
u=os.environ["POSTGRES_USER"]; p=os.environ["POSTGRES_PASSWORD"]; d=os.environ["POSTGRES_DB"]
url=f"postgresql+psycopg2://{u}:{p}@db:5432/{d}"
print("DB URL:", url.replace(p,"***"))
e=create_engine(url); insp=inspect(e)
print("Tables:", insp.get_table_names())
PY
' || true

# ---------- Ingest & sample ----------
say "Ingest trending (expect 200 {'ok':true})"
set +e
ING=$(curl -s -o /tmp/ing.out -w "%{http_code}" -X POST "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/ingest/tmdb/trending")
set -e
echo "Ingest => HTTP $ING"; [ -s /tmp/ing.out ] && echo "Body:" && head -c 400 /tmp/ing.out && echo

say "List 3 movies (via gateway)"
curl -s "http://127.0.0.1:${HOST_GATEWAY_PORT}/api/movies?limit=3" | head -c 1200; echo

say "Last logs (short)"
docker compose -p "$PROJECT" logs --no-color --tail=120 backend || true
docker compose -p "$PROJECT" logs --no-color --tail=120 worker  || true

say "Done."
