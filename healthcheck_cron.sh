#!/usr/bin/env bash

set -o pipefail

HEALTH_URL="${HEALTH_URL:-http://localhost:8000/health}"
LOG_DIR="${LOG_DIR:-/var/log}"
FAILURE_LOG="${LOG_DIR}/llm_health_failures.log"
TIMEOUT_SECS=5

if [ ! -w "$LOG_DIR" ] 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOG_DIR="${SCRIPT_DIR}/logs"
    FAILURE_LOG="${LOG_DIR}/llm_health_failures.log"
fi
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
RESPONSE_TEMP=$(mktemp)

HTTP_STATUS=$(curl -s -S --max-time "$TIMEOUT_SECS" -o "$RESPONSE_TEMP" -w "%{http_code}" "$HEALTH_URL" 2>&1)
CURL_EXIT_CODE=$?

if [ "$CURL_EXIT_CODE" -ne 0 ]; then
    echo "[$TIMESTAMP] [CRITICAL] Endpoint unreachable ($HEALTH_URL). curl exit code: $CURL_EXIT_CODE. Error: $HTTP_STATUS" >> "$FAILURE_LOG"
elif [ "$HTTP_STATUS" -ne 200 ]; then
    RESPONSE_BODY=$(cat "$RESPONSE_TEMP" 2>/dev/null | tr -d '\n')
    echo "[$TIMESTAMP] [ERROR] Health probe failed with HTTP $HTTP_STATUS. Payload: $RESPONSE_BODY" >> "$FAILURE_LOG"
else
    if grep -q '"status": *"degraded"' "$RESPONSE_TEMP" 2>/dev/null; then
        RESPONSE_BODY=$(cat "$RESPONSE_TEMP" 2>/dev/null | tr -d '\n')
        echo "[$TIMESTAMP] [WARNING] Service degraded (Redis cache unreachable): $RESPONSE_BODY" >> "$FAILURE_LOG"
    fi
fi

rm -f "$RESPONSE_TEMP"
