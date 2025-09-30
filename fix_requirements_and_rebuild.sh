#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"

say(){ echo -e "\n=== $* ==="; }

cd "$ROOT"

# 1) Ensure backend/requirements.txt
if [ ! -f backend/requirements.txt ]; then
  say "Creating backend/requirements.txt"
  cat > backend/requirements.txt <<'REQ'
fastapi==0.111.*
uvicorn[standard]==0.30.*
httpx==0.27.*
pydantic==2.*
SQLAlchemy==2.*
alembic==1.13.*
psycopg2-binary==2.9.*
python-dotenv==1.0.*
orjson==3.*
tenacity==8.*
REQ
else
  say "backend/requirements.txt already exists (keeping as-is)"
fi

# 2) Ensure worker/requirements.txt (same deps as backend)
if [ ! -f worker/requirements.txt ]; then
  say "Creating worker/requirements.txt"
  cat > worker/requirements.txt <<'REQ'
fastapi==0.111.*
uvicorn[standard]==0.30.*
httpx==0.27.*
pydantic==2.*
SQLAlchemy==2.*
alembic==1.13.*
psycopg2-binary==2.9.*
python-dotenv==1.0.*
orjson==3.*
tenacity==8.*
REQ
else
  say "worker/requirements.txt already exists (keeping as-is)"
fi

# 3) Rebuild backend + worker (frontend build was canceled earlier; keep it too)
say "Rebuilding images…"
docker compose -p "$PROJECT" build --no-cache backend worker frontend

# 4) Up
say "Starting stack…"
docker compose -p "$PROJECT" up -d

# 5) Show status
say "Stack status"
docker compose -p "$PROJECT" ps

# 6) Confirm token & TMDb reachability inside backend
say "TMDb checks inside backend"
docker compose -p "$PROJECT" exec -T backend bash -lc '
  echo -n "TMDB_API_KEY len: "; echo -n "$TMDB_API_KEY" | wc -c
  echo -n "/3/configuration => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" \
    https://api.themoviedb.org/3/configuration || true
  echo -n "/3/trending/movie/day => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" \
    "https://api.themoviedb.org/3/trending/movie/day?language=en-US&page=1" || true
'

# 7) Try ingest once (via gateway)
say "Trigger ingest (gateway)"
set +e
ING=$(curl -s -o /tmp/ing_fix.out -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending)
set -e
echo "Ingest => HTTP $ING"
[ -s /tmp/ing_fix.out ] && echo "Body:" && head -c 400 /tmp/ing_fix.out && echo

# 8) Small sample list
say "List 3 movies"
curl -s "http://127.0.0.1:9088/api/movies?limit=3" | head -c 1200; echo

# 9) Recent logs for any errors
say "Recent backend logs"
docker compose -p "$PROJECT" logs --no-color --tail=120 backend || true
say "Recent worker logs"
docker compose -p "$PROJECT" logs --no-color --tail=120 worker  || true

say "Done."
