#!/usr/bin/env bash
set -e
cd /opt/ai-movie-platform
docker compose -p aimr build
docker compose -p aimr up -d
docker compose -p aimr ps
