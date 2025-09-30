#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT" || { echo "Root not found: $ROOT"; exit 1; }

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# ---------- config ----------
TMDB_PIN_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"
NEED_SERVICES=("db" "backend" "frontend" "gateway" "worker")

# ---------- token helpers ----------
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
  [[ "${tok:0:3}" == "eyJ" ]] || { echo "Not a v4 JWT (must start with eyJ)"; return 1; }
  [[ "$dots" -eq 2 ]] || { echo "Invalid JWT shape — needs exactly 2 dots"; return 1; }
  [[ "$len" -ge 100 ]] || { echo "Too short (<100) — likely truncated"; return 1; }
  return 0
}
probe_tmdb_200(){ # returns 0 on 200
  local tok="$1"
  local code
  code=$(curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}" \
    -H 'accept: application/json' -H "Authorization: Bearer '"$tok"'" \
    https://api.themoviedb.org/3/configuration || true)
  echo "TMDb /3/configuration => $code"
  [[ "$code" == "200" ]]
}

# ---------- Step 0: host egress ----------
say "Host egress to TMDb (force IPv4)"
HOST_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" https://api.themoviedb.org/3 || true)
echo "Host -> TMDb /3 => $HOST_CODE (204/401 is fine; 000 means blocked)"

# ---------- Step 1: start containers ----------
say "Docker compose status / start"
docker compose -p "$PROJECT" up -d "${NEED_SERVICES[@]}" >/dev/null
docker compose -p "$PROJECT" ps

# ---------- Step 2: hard-pin IPv4 inside backend/worker ----------
say "Force-pin api.themoviedb.org -> $TMDB_PIN_IP inside backend & worker"
for svc in backend worker; do
  docker compose -p "$PROJECT" exec -T "$svc" bash -lc "
    set -e
    tmp=\$(mktemp)
    # Remove ANY existing api.themoviedb.org lines then prepend ours
    grep -v -i '^[[:space:][:xdigit:]\.:]*[[:space:]]\+api\.themoviedb\.org' /etc/hosts > \"\$tmp\" || true
    printf '%s\t%s\t# pinned by fixer\n' '$TMDB_PIN_IP' 'api.themoviedb.org' > /etc/hosts
    cat \"\$tmp\" >> /etc/hosts
    rm -f \"\$tmp\"
    echo '--- /etc/hosts (head) ---'
    sed -n '1,8p' /etc/hosts
    echo '--- getent hosts ---'
    getent hosts api.themoviedb.org || true
    echo '--- curl -4 /3 (no auth) ---'
    curl -4 -s -o /dev/null -w '%{http_code}\n' https://api.themoviedb.org/3 || true
  " || true
done

# ---------- Step 3: obtain VALID token ----------
say "Validate your REAL TMDb v4 Read Access Token"
RAW_INPUT="${1:-}"
TOK="$(normalize_token "$RAW_INPUT")"
ATTEMPTS=0
while true; do
  ATTEMPTS=$((ATTEMPTS+1))
  if check_token_shape "$TOK"; then
    probe_tmdb_200 "$TOK" && break || echo "Token rejected by TMDb (not 200)."
  fi
  if [[ $ATTEMPTS -ge 3 ]]; then fail "Need a REAL v4 token. Open TMDb → Settings → API → 'API Read Access Token (v4 auth)'. Copy full line."; fi
  echo -n "Paste REAL v4 token (single line, no quotes/no Bearer): "
  read -r TOK
  TOK="$(normalize_token "$TOK")"
done
echo -n "$TOK" > .tmdb_v4_clean

# ---------- Step 4: write to .env & reload backend ----------
say "Write token to .env (TMDB_API_KEY) and reload backend"
if [[ ! -f .env ]]; then
  cat > .env <<ENV
APP_ENV=prod
TZ=Asia/Kolkata
HOST_GATEWAY_PORT=9088
HOST_BACKEND_PORT=9087
POSTGRES_DB=aimovie
POSTGRES_USER=aimovie
POSTGRES_PASSWORD=aimovie_pass_123
TMDB_API_KEY=
NEXT_PUBLIC_API_BASE_URL=/api
ENV
fi
sed -i "s|^TMDB_API_KEY=.*|TMDB_API_KEY=$(cat .tmdb_v4_clean)|" .env
docker compose -p "$PROJECT" up -d backend >/dev/null

say "Confirm token INSIDE backend & TMDb 200"
docker compose -p "$PROJECT" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p "$PROJECT" exec -T backend bash -lc \
  'curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration'

# ---------- Step 5: alembic repair + migrate ----------
say "Ensure alembic.ini has sqlalchemy.url"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
DB_URL="postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@db:5432/$POSTGRES_DB"
if [ -f alembic.ini ]; then
  if grep -q "^sqlalchemy.url" alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    printf "\nsqlalchemy.url = %s\n" "$DB_URL" >> alembic.ini
  fi
else
  echo "alembic.ini missing"; exit 1
fi
'

say "Replace alembic/env.py with safe minimal version + run upgrade"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
python - << "PY"
from pathlib import Path
p = Path("alembic/env.py")
p.write_text("""from alembic import context
from sqlalchemy import create_engine, pool

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
print("env.py replaced OK")
PY
alembic upgrade head || alembic stamp head
'

# ---------- Step 6: health → ingest → list ----------
say "Health checks"
curl -fsS http://127.0.0.1:9087/api/health && echo
curl -fsS http://127.0.0.1:9088/healthz && echo

say "Ingest trending (expect 200 / {\"ok\":true})"
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending || true

say "List 3 movies"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || true
echo

# ---------- Step 7: diagnostics bundle ----------
say "Collect diagnostics bundle"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="diag_$TS"
mkdir -p "$OUT"
{
  echo "# host egress"; echo "HOST_CODE=$HOST_CODE"
  echo; echo "# docker ps"; docker compose -p "$PROJECT" ps
  echo; echo "# .env (masked)"; awk '{gsub(/TMDB_API_KEY=.*/,"TMDB_API_KEY=***MASKED***"); print}' .env
  echo; echo "# backend token length"; docker compose -p "$PROJECT" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
  echo; echo "# backend->TMDb /3/configuration code"; docker compose -p "$PROJECT" exec -T backend bash -lc \
    'curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true'
  echo; echo "# /etc/hosts heads"; for s in backend worker; do
    echo "--- $s /etc/hosts head ---"
    docker compose -p "$PROJECT" exec -T "$s" bash -lc 'sed -n "1,12p" /etc/hosts' || true
  done
  echo; echo "# alembic.ini"; docker compose -p "$PROJECT" exec -T backend bash -lc 'sed -n "1,120p" alembic.ini || true'
  echo; echo "# alembic/env.py"; docker compose -p "$PROJECT" exec -T backend bash -lc 'sed -n "1,120p" alembic/env.py || true'
} > "$OUT/summary.txt" 2>&1

docker compose -p "$PROJECT" logs --tail=300 backend  > "$OUT/log_backend.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 gateway  > "$OUT/log_gateway.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 frontend > "$OUT/log_frontend.txt" 2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 worker   > "$OUT/log_worker.txt"   2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 db       > "$OUT/log_db.txt"       2>&1 || true

tar -czf "diagnostics_${TS}.tar.gz" "$OUT"; rm -rf "$OUT"
say "DONE. Diagnostics saved: $(ls -1 diagnostics_${TS}.tar.gz)"
