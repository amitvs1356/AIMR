#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT" || { echo "Root not found: $ROOT"; exit 1; }

say(){ echo -e "\n=== $* ==="; }
fail(){ echo -e "\n#### FAILED: $* ####"; exit 1; }

# -------- INPUT: real TMDb v4 token (single line) ----------
REAL_TOKEN="${1:-}"
if [[ -z "$REAL_TOKEN" ]]; then
  echo "Usage: $0 '<TMDb v4 Read Access Token (eyJ... with exactly two dots)>'"
  exit 2
fi

# -------- Step 0: host IPv4 reachability ----------
say "Host egress to TMDb (force IPv4)"
HOST_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" https://api.themoviedb.org/3 || true)
echo "Host -> TMDb /3 => $HOST_CODE (204/401 is fine; 000 means blocked)"

if [[ "$HOST_CODE" == "000" ]]; then
  echo "WARN: Host cannot reach TMDb over IPv4. We'll try pinning an IP later inside containers."
fi

# Pick a known working IP (you already tested 65.9.112.49)
TMDB_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"

# -------- Step 1: bring-compose up (ensure containers exist) ----------
say "Docker compose status / start"
docker compose -p "$PROJECT" up -d db backend frontend gateway worker >/dev/null
docker compose -p "$PROJECT" ps

# -------- Step 2: pin TMDb host inside containers for this run ----------
say "Pin 'api.themoviedb.org' to $TMDB_IP inside backend/worker (runtime only)"
for SVC in backend worker; do
  docker compose -p "$PROJECT" exec -T "$SVC" bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '$TMDB_IP api.themoviedb.org' >> /etc/hosts" || true
  docker compose -p "$PROJECT" exec -T "$SVC" bash -lc "getent hosts api.themoviedb.org || true" || true
done

# -------- Step 3: doctor the token ----------
say "Validate your REAL TMDb v4 token"
RAW="$REAL_TOKEN"
TOK="$(printf '%s' "$RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\"//' -e 's/\"$//' -e "s/^'//" -e "s/'$//")"
if [[ "$TOK" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then TOK="${BASH_REMATCH[1]}"; fi
LEN=${#TOK}; DOTS=$(awk -F. '{print NF-1}' <<<"$TOK")
echo "Length: $LEN"
echo "Dots:   $DOTS (must be exactly 2)"
echo "Prefix: $(printf '%s' "$TOK" | head -c 5)..."

[[ "${TOK:0:3}" != "eyJ" ]] && fail "Not a v4 JWT (must start with eyJ)"
[[ $DOTS -ne 2 ]] && fail "Invalid JWT shape — needs exactly 2 dots (header.payload.signature)"
[[ $LEN -lt 100 ]] && fail "Token too short (<100). Likely truncated or wrong value."

say "Call TMDb /3/configuration with your token (expect 200)"
CONF_CODE=$(curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}" \
  -H 'accept: application/json' -H "Authorization: Bearer ${TOK}" \
  https://api.themoviedb.org/3/configuration || true)
echo "TMDb /3/configuration => $CONF_CODE"
[[ "$CONF_CODE" != "200" ]] && fail "TMDb rejected the token. Copy the v4 Read Access Token EXACTLY from TMDb settings."

echo -n "$TOK" > .tmdb_v4_clean

# -------- Step 4: write token into .env ----------
say "Write token into .env as TMDB_API_KEY"
if [[ ! -f .env ]]; then
  echo "Creating .env"
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

# restart backend to pick env
docker compose -p "$PROJECT" up -d backend >/dev/null

say "Confirm token INSIDE backend container"
docker compose -p "$PROJECT" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p "$PROJECT" exec -T backend bash -lc \
  'curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration'

# -------- Step 5: fix Alembic env.py and run migrations ----------
say "Ensure alembic.ini has sqlalchemy.url"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
DB_URL="postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@db:5432/$POSTGRES_DB"
if [ -f alembic.ini ]; then
  if grep -q "^sqlalchemy.url" alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    awk -v url="$DB_URL" "
      BEGIN{printed=0}
      {print}
      END{
        print \"sqlalchemy.url = \" url
      }" alembic.ini > alembic.ini.tmp && mv alembic.ini.tmp alembic.ini
  fi
else
  echo "alembic.ini missing"; exit 1
fi
'

say "Replace alembic/env.py with a minimal safe version + migrate"
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

# -------- Step 6: health, ingest, sample list ----------
say "Health checks"
curl -fsS http://127.0.0.1:9087/api/health && echo
curl -fsS http://127.0.0.1:9088/healthz && echo

say "Ingest trending (expect 200 / {\"ok\":true})"
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending || true

say "List 3 movies (may be empty if ingest skipped/failed)"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" || true
echo

# -------- Step 7: collect diagnostics ----------
say "Collect diagnostics bundle"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="diag_$TS"
mkdir -p "$OUTDIR"

{
  echo "# host network"
  echo "HOST_CODE=$HOST_CODE"

  echo
  echo "# docker ps"
  docker compose -p "$PROJECT" ps

  echo
  echo "# .env (masked)"
  awk '{gsub(/TMDB_API_KEY=.*/,"TMDB_API_KEY=***MASKED***"); print}' .env

  echo
  echo "# backend env token length"
  docker compose -p "$PROJECT" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'

  echo
  echo "# backend -> tmdb /3/configuration code"
  docker compose -p "$PROJECT" exec -T backend bash -lc \
    'curl -4 --http1.1 --tlsv1.2 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true'

  echo
  echo "# alembic.ini head"
  docker compose -p "$PROJECT" exec -T backend bash -lc 'sed -n "1,120p" alembic.ini || true'

  echo
  echo "# env.py head"
  docker compose -p "$PROJECT" exec -T backend bash -lc 'sed -n "1,120p" alembic/env.py || true'

} > "$OUTDIR/summary.txt" 2>&1

# save container logs (short tails so bundle stays small)
docker compose -p "$PROJECT" logs --tail=300 backend  > "$OUTDIR/log_backend.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 gateway  > "$OUTDIR/log_gateway.txt"  2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 frontend > "$OUTDIR/log_frontend.txt" 2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 worker   > "$OUTDIR/log_worker.txt"   2>&1 || true
docker compose -p "$PROJECT" logs --tail=300 db       > "$OUTDIR/log_db.txt"       2>&1 || true

tar -czf "diagnostics_${TS}.tar.gz" "$OUTDIR"
rm -rf "$OUTDIR"

say "DONE. Diagnostics saved:"
ls -l "diagnostics_${TS}.tar.gz"

echo
say "NEXT STEPS"
cat <<NEXT
1) Make sure you used the REAL v4 token (2 dots, long). If token doctor failed above, copy again from TMDb Settings → API → "API Read Access Token (v4 auth)".
2) If ingest still fails, open the diagnostics tarball; share summary.txt and log_backend.txt with me.
NEXT
