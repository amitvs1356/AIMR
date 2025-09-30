#!/usr/bin/env bash
set -euo pipefail

# Prefer IPv4 inside the container (survives restarts because it runs every boot)
if [ -f /etc/gai.conf ] && grep -q "^#.*precedence ::ffff:0:0/96" /etc/gai.conf; then
  sed -i "s/^#\s*\(precedence ::ffff:0:0\/96\s\+100\)/\1/" /etc/gai.conf || true
fi

DB_URL="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

# Ensure alembic.ini has sqlalchemy.url
if [ -f alembic.ini ]; then
  if grep -q '^sqlalchemy\.url' alembic.ini; then
    sed -i "s|^sqlalchemy\.url.*|sqlalchemy.url = ${DB_URL}|" alembic.ini
  else
    echo "sqlalchemy.url = ${DB_URL}" >> alembic.ini
  fi
fi

# Ensure alembic/env.py basic online/offline runners
if [ -f alembic/env.py ]; then
python - <<'PY'
from pathlib import Path
p = Path("alembic/env.py")
p.write_text("""from alembic import context
from sqlalchemy import create_engine, pool
from logging.config import fileConfig
config = context.config
target_metadata = None
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
