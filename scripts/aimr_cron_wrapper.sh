#!/usr/bin/env bash
source /root/aimr_env || true
set -euo pipefail
LOG=/var/log/aimr-enqueue.log

{
  echo "=== $(date -Is) aimr_enqueue START ==="

  set +e
  /bin/bash /root/aimr_enqueue.sh
  rc=$?
  set -e

  echo "=== $(date -Is) aimr_enqueue END rc=${rc} ==="

  if [ "$rc" -ne 0 ]; then
    logger -t aimr-cron "enqueue FAILED rc=${rc}"

    # --- Optional Telegram alert (fill real values) ---
    TG_BOT="<REAL_BOT_TOKEN>"      # bot token
    TG_CHAT="<CHAT_ID>"     # chat id
    if [ -n "${TG_BOT}" ] && [[ "${TG_BOT}" != "123456:ABC..." ]]; then
      curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
        -d chat_id="$TG_CHAT" \
        -d text="aimr enqueue FAILED on $(hostname) rc=${rc} at $(date -Is)" >/dev/null 2>&1 || true
    fi
    # -----------------------------------------------
  fi

  exit "$rc"
} >>"$LOG" 2>&1
