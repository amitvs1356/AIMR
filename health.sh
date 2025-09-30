#!/usr/bin/env bash
set -e
curl -fsS http://127.0.0.1:9087/api/health && echo
curl -I http://127.0.0.1:9088/ | head -n1
curl -fsS http://127.0.0.1:9088/api/health && echo
