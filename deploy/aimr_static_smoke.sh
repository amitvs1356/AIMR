#!/usr/bin/env bash
set -euo pipefail

echo "[1] Containers:"
docker compose ps

echo "[2] Backend internals:"
docker compose exec -T backend sh -lc '
python - <<PY
import ast, pathlib, PIL, os
for f in ("/app/app/main.py","/app/app/api/routes.py"):
    ast.parse(pathlib.Path(f).read_text())
print(" - syntax OK; Pillow:", PIL.__version__)
print(" - static exists:", os.path.isdir("/app/app/static"))
print(" - posters exists:", os.path.isdir("/app/app/static/posters"))
PY
'

echo "[3] Gateway /static block (should print the block):"
docker compose exec -T gateway sh -lc 'nginx -T | sed -n "/location \\/static\\//,/}/p"'

echo "[4] Health via gateway:"
curl -fsS http://127.0.0.1:9088/api/health && echo

echo "[5] Touch static and fetch sentinel:"
curl -fsS -X POST http://127.0.0.1:9088/api/static_touch && echo
curl -fsS http://127.0.0.1:9088/static/posters/test.txt && echo

echo "[6] Generate posters and probe one:"
json=$(curl -fsS http://127.0.0.1:9088/api/auto_generate)
echo "$json"
one=$(printf "%s" "$json" | sed -n 's/.*"poster":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
[ -n "${one:-}" ] && curl -I "http://127.0.0.1:9088$one" || echo "No poster parsed"
echo "[OK]"
