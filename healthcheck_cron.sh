#!/usr/bin/env bash
# ==============================================================================
# Host Cron Health Monitoring Script for LLM Inference API
# Pings /health endpoint and logs failures with timestamps and error details.
#
# Crontab Installation Example (runs every minute):
#   * * * * * /path/to/healthcheck_cron.sh >> /var/log/llm_cron_runner.log 2>&1
# ==============================================================================

set -o pipefail

# Configuration
HEALTH_URL="${HEALTH_URL:-http://localhost:8000/health}"
LOG_DIR="${LOG_DIR:-/var/log}"
FAILURE_LOG="${LOG_DIR}/llm_health_failures.log"
TIMEOUT_SECS=5

# Ensure log directory exists if user has permissions, otherwise fallback to local logs dir
if [ ! -w "$LOG_DIR" ] 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOG_DIR="${SCRIPT_DIR}/logs"
    FAILURE_LOG="${LOG_DIR}/llm_health_failures.log"
fi
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
RESPONSE_TEMP=$(mktemp)

# Probe the endpoint
HTTP_STATUS=$(curl -s -S --max-time "$TIMEOUT_SECS" -o "$RESPONSE_TEMP" -w "%{http_code}" "$HEALTH_URL" 2>&1)
CURL_EXIT_CODE=$?

if [ "$CURL_EXIT_CODE" -ne 0 ]; then
    # Network / connection failure (API down / not listening)
    echo "[$TIMESTAMP] [CRITICAL] Endpoint unreachable ($HEALTH_URL). curl exit code: $CURL_EXIT_CODE. Error: $HTTP_STATUS" >> "$FAILURE_LOG"
elif [ "$HTTP_STATUS" -ne 200 ]; then
    # HTTP error (e.g. 500, 502, 503 Service Unavailable)
    RESPONSE_BODY=$(cat "$RESPONSE_TEMP" 2>/dev/null | tr -d '\n')
    echo "[$TIMESTAMP] [ERROR] Health probe failed with HTTP $HTTP_STATUS. Payload: $RESPONSE_BODY" >> "$FAILURE_LOG"
else
    # HTTP 200 covers both "healthy" and "degraded" (model up, Redis cache unreachable)
    if grep -q '"status": *"degraded"' "$RESPONSE_TEMP" 2>/dev/null; then
        RESPONSE_BODY=$(cat "$RESPONSE_TEMP" 2>/dev/null | tr -d '\n')
        echo "[$TIMESTAMP] [WARNING] Service degraded (Redis cache unreachable): $RESPONSE_BODY" >> "$FAILURE_LOG"
    fi
fi

# Cleanup
rm -f "$RESPONSE_TEMP"
