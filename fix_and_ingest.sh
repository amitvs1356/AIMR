#!/usr/bin/env bash
set -e
cd /opt/ai-movie-platform
echo "=== check backend health ==="
curl -fsS http://127.0.0.1:9087/api/health || (echo "backend not up"; exit 1)
echo "=== check TMDb token ==="
docker compose -p aimr exec backend bash -lc 'echo -n "$TMDB_API_KEY" | wc -c'
docker compose -p aimr exec backend bash -lc 'curl -s -o /dev/null -w "%{http_code}\n" https://api.themoviedb.org/3/configuration -H "Authorization: Bearer $TMDB_API_KEY"'
echo "=== run ingest trending ==="
curl -fsS -X POST http://127.0.0.1:9088/api/ingest/tmdb/trending
echo
echo "=== sample list ==="
curl -fsS "http://127.0.0.1:9088/api/movies?limit=3" | jq . || true
