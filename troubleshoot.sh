#!/usr/bin/env bash
set -u  # (जानबूझकर -e नहीं रखा ताकि fail पर भी आगे के steps/diagnostics चलें)

PROJECT=aimr
API="http://127.0.0.1:9087/api/health"
GATEWAY="http://127.0.0.1:9088/api/health"

echo "=== [1/7] Rebuild backend image (ensure fresh alembic.ini picked) ==="
docker compose -p "$PROJECT" build --no-cache backend

echo
echo "=== [2/7] Run Alembic migrations manually ==="
docker compose -p "$PROJECT" run --rm backend bash -lc 'alembic upgrade head'
ALEMBIC_RC=$?
if [ $ALEMBIC_RC -ne 0 ]; then
  echo "!! Alembic failed with code $ALEMBIC_RC — showing backend container logs (if any):"
  docker compose -p "$PROJECT" logs --tail=200 backend || true
  exit 1
fi

echo
echo "=== [3/7] Start/Restart backend, frontend, gateway ==="
docker compose -p "$PROJECT" up -d backend frontend gateway

echo
echo "=== [4/7] Current container status ==="
docker compose -p "$PROJECT" ps

echo
echo "=== [5/7] Backend health check (9087) ==="
curl -fsS "$API" || echo "[X] backend not responding"

echo
echo "=== [6/7] Gateway health check (9088 -> backend) ==="
curl -fsS "$GATEWAY" || echo "[X] gateway not responding"

echo
echo "=== [7/7] If any check failed, show quick logs ==="
echo "---- backend logs (tail 120) ----"
docker compose -p "$PROJECT" logs --tail=120 backend || true
echo "---- gateway logs (tail 80) ----"
docker compose -p "$PROJECT" logs --tail=80 gateway || true
echo "---- db logs (tail 40) ----"
docker compose -p "$PROJECT" logs --tail=40 db || true

echo
echo "[✓] Troubleshoot run complete."
