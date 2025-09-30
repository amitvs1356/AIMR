#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

say(){ echo -e "\n=== $* ==="; }

say "Show stack status"
docker compose -p "$PROJECT" ps || true

say "Hit ingest endpoint (expect 200). If 500, we capture logs next."
set +e
INGEST_CODE=$(curl -s -o /tmp/ingest.out -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending)
set -e
echo "Gateway /api/ingest/tmdb/trending => HTTP $INGEST_CODE"
[ -s /tmp/ingest.out ] && echo "Body:" && head -c 400 /tmp/ingest.out && echo

say "Backend last logs (tail 200)"
docker compose -p "$PROJECT" logs --no-color --tail=200 backend || true

say "Worker last logs (tail 120)"
docker compose -p "$PROJECT" logs --no-color --tail=120 worker || true

say "Check TMDb egress + token inside backend"
docker compose -p "$PROJECT" exec -T backend bash -lc '
  echo -n "TMDB_API_KEY length: "; echo -n "$TMDB_API_KEY" | wc -c
  echo "GET /3/configuration (expect 200):"
  curl -4 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true
  echo "GET /3/trending/movie/day (expect 200):"
  curl -4 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" "https://api.themoviedb.org/3/trending/movie/day?language=en-US&page=1" || true
'

say "DB connectivity + list tables from inside backend"
docker compose -p "$PROJECT" exec -T backend bash -lc '
python - <<PY
import os
from sqlalchemy import create_engine, inspect
db = f"postgresql+psycopg2://{os.environ['POSTGRES_USER']}:{os.environ['POSTGRES_PASSWORD']}@db:5432/{os.environ['POSTGRES_DB']}"
print("DB URL:", db.replace(os.environ["POSTGRES_PASSWORD"], "***"))
e = create_engine(db)
insp = inspect(e)
print("Tables:", insp.get_table_names())
PY
' || true

say "If no app tables are present, re-run migrations safely"
docker compose -p "$PROJECT" exec -T backend bash -lc '
set -e
if [ -f alembic.ini ]; then
  echo "alembic.ini present. Ensuring sqlalchemy.url…"
  DB_URL="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"
  if grep -q "^sqlalchemy\.url" alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    echo "sqlalchemy.url = ${DB_URL}" >> alembic.ini
  fi
  echo "Run: alembic upgrade head (or stamp head if empty)…"
  alembic upgrade head || alembic stamp head || true
else
  echo "alembic.ini not found (app may use raw SQL). Skipping migration step."
fi
'

say "Restart backend & worker to pick up any changes"
docker compose -p "$PROJECT" restart backend worker

say "Wait 5s and re-test ingest"
sleep 5
set +e
INGEST_CODE2=$(curl -s -o /tmp/ingest2.out -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending)
set -e
echo "Ingest #2 => HTTP $INGEST_CODE2"
[ -s /tmp/ingest2.out ] && echo "Body:" && head -c 400 /tmp/ingest2.out && echo

say "Try listing 3 movies"
set +e
curl -s "http://127.0.0.1:9088/api/movies?limit=3" | tee /tmp/movies3.json | head -c 1200
echo
set -e

say "Final backend tail after tests"
docker compose -p "$PROJECT" logs --no-color --tail=200 backend || true

echo -e "\n==> Done. If still failing, copy everything above (especially any Python traceback) and send it."
