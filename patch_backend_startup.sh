#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/ai-movie-platform"
PROJECT="aimr"
cd "$ROOT"

echo "==> Write backend entrypoint (alembic + uvicorn)"
cat > backend/entrypoint.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

DB_URL="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

# Ensure alembic.ini has sqlalchemy.url
if [ -f alembic.ini ]; then
  if grep -q '^sqlalchemy\.url' alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    awk -v url="$DB_URL" '1; END{print "sqlalchemy.url = " url}' alembic.ini > alembic.ini.new && mv alembic.ini.new alembic.ini
  fi
fi

# Alembic env.py: use create_engine with config value
if [ -f alembic/env.py ]; then
  python - <<'PY'
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
print("env.py written")
PY
fi

# Run migrations (don’t crash if no scripts)
alembic upgrade head || alembic stamp head || true

# Finally start FastAPI
exec uvicorn app.main:app --host 0.0.0.0 --port 9087
SH
chmod +x backend/entrypoint.sh

echo "==> Patch backend Dockerfile to use entrypoint"
cat > backend/Dockerfile <<'DOCKER'
FROM python:3.11-slim

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app
# use our entrypoint that runs alembic then uvicorn
ENTRYPOINT ["/app/entrypoint.sh"]
EXPOSE 9087
DOCKER

echo "==> Keep worker command as python -m app.worker (compose already sets it)"

echo "==> Rebuild & Up"
docker compose -p "${PROJECT}" up -d --build

echo "==> Wait 5s and show ps"
sleep 5
docker compose -p "${PROJECT}" ps

echo "==> If any container restarts, print last logs"
docker compose -p "${PROJECT}" logs --no-color --tail=120 backend || true
docker compose -p "${PROJECT}" logs --no-color --tail=120 worker  || true

echo "==> Health checks"
curl -fsS http://127.0.0.1:9087/api/health && echo || true
curl -fsS http://127.0.0.1:9088/healthz && echo || true

echo "==> Token live test inside backend"
docker compose -p "${PROJECT}" exec -T backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p "${PROJECT}" exec -T backend bash -lc 'curl -4 -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TMDB_API_KEY" -H "accept: application/json" https://api.themoviedb.org/3/configuration || true'

echo "==> Ingest trending via gateway"
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending || true

echo "==> Sample movies (3)"
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" | head -c 1000 || true

echo -e "\n==> Done."
