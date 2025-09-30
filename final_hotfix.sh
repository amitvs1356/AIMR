#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"

say(){ echo -e "\n=== $* ==="; }

cd "$ROOT"

# 0) Quick status
say "Stack status (before)"
docker compose -p "$PROJECT" ps || true

# 1) Pin TMDb IPv4 inside backend (runtime /etc/hosts)
TMDB_IP="${TMDB_IP_OVERRIDE:-65.9.112.49}"
say "Pinning api.themoviedb.org -> ${TMDB_IP} inside backend"
docker compose -p "$PROJECT" exec -T backend bash -lc "grep -q 'api.themoviedb.org' /etc/hosts || echo '${TMDB_IP} api.themoviedb.org' >> /etc/hosts; head -n 5 /etc/hosts | cat" || true

# 2) Verify token works to /3/configuration and /3/trending (inside backend)
say "TMDb reachability (inside backend)"
docker compose -p "$PROJECT" exec -T backend bash -lc '
  echo -n "TMDB_API_KEY len: "; echo -n "$TMDB_API_KEY" | wc -c
  echo -n "GET /3/configuration => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true
  echo -n "GET /3/trending/movie/day => "; curl -4 --http1.1 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" "https://api.themoviedb.org/3/trending/movie/day?language=en-US&page=1" || true
' || true

# 3) DB schema hotfix (idempotent ALTERs) from *db* container
say "Patching DB schema (add missing columns if needed)"
docker compose -p "$PROJECT" exec -T db bash -lc '
psql -U "$POSTGRES_USER" "$POSTGRES_DB" <<SQL
BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = ''movies'' AND column_name = ''popularity'') THEN
    ALTER TABLE movies ADD COLUMN popularity DOUBLE PRECISION DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = ''movies'' AND column_name = ''vote_average'') THEN
    ALTER TABLE movies ADD COLUMN vote_average DOUBLE PRECISION DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = ''movies'' AND column_name = ''vote_count'') THEN
    ALTER TABLE movies ADD COLUMN vote_count INTEGER DEFAULT 0;
  END IF;
END $$;
COMMIT;
SQL
' || true

# 4) Restart backend (pick up any changes), and stop worker (avoid import spam)
say "Restart backend; temporarily stop worker"
docker compose -p "$PROJECT" restart backend || true
docker compose -p "$PROJECT" stop worker || true

# 5) Health checks
say "Health checks"
curl -fsS http://127.0.0.1:9087/api/health && echo || true
curl -fsS http://127.0.0.1:9088/healthz && echo || true

# 6) Trigger ingest via gateway
say "Trigger ingest (/api/ingest/tmdb/trending via gateway)"
set +e
ING_CODE=$(curl -s -o /tmp/ing_hotfix.out -w "%{http_code}" -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending)
set -e
echo "Ingest => HTTP $ING_CODE"
[ -s /tmp/ing_hotfix.out ] && echo "Body:" && head -c 400 /tmp/ing_hotfix.out && echo

# 7) Try list 3 movies
say "List 3 movies"
curl -s "http://127.0.0.1:9088/api/movies?limit=3" | head -c 1200; echo

# 8) Tail recent logs
say "Recent backend logs"
docker compose -p "$PROJECT" logs --no-color --tail=120 backend || true
say "Recent worker logs (stopped may be empty)"
docker compose -p "$PROJECT" logs --no-color --tail=60 worker || true

say "Done."
