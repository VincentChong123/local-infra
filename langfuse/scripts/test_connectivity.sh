#!/usr/bin/env bash
# ==============================================================================
# test_connectivity.sh - Stage 1: Pure OpenTelemetry OTLP Ingestion via curl
# ==============================================================================
# Directly verifies network connectivity, host route, and Langfuse OTLP HTTP
# receiver (/api/public/otel/v1/traces) using raw curl (zero Python/AGY dependencies).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Resolve Environment & Credentials
ENV_FILE="${ENV_FILE:-}"
if [ -z "$ENV_FILE" ]; then
    for candidate in "${PWD}/.env" "${SCRIPT_DIR}/../.env" "$HOME/.gemini/antigravity-cli/.env"; do
        if [ -f "$candidate" ]; then
            ENV_FILE="$candidate"
            break
        fi
    done
fi

if [ -n "$ENV_FILE" ]; then
    echo "==> Loading environment from $ENV_FILE..."
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
fi

LANGFUSE_PUB="${LANGFUSE_PUBLIC_KEY_AGY:-${LANGFUSE_PUBLIC_KEY:-}}"
LANGFUSE_SEC="${LANGFUSE_SECRET_KEY_AGY:-${LANGFUSE_SECRET_KEY:-}}"
LANGFUSE_PORT="${LANGFUSE_UI_PORT:-3100}"

if [ -z "$LANGFUSE_PUB" ] || [ -z "$LANGFUSE_SEC" ]; then
    echo "[ERROR] Missing LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY in environment/dotenv." >&2
    exit 1
fi

# Auto-detect host IP from default route if not explicitly set
HOST_IP="${HOST_IP:-$(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "127.0.0.1")}"
LANGFUSE_HOST="${LANGFUSE_CONNECT_IP:-$HOST_IP}"
if [ "$LANGFUSE_HOST" = "127.0.0.1" ] || [ "$LANGFUSE_HOST" = "localhost" ]; then
    if ! curl -s --connect-timeout 0.5 "http://${LANGFUSE_HOST}:${LANGFUSE_PORT}/api/public/health" >/dev/null 2>&1; then
        LANGFUSE_HOST="$HOST_IP"
    fi
fi
LANGFUSE_URL="http://${LANGFUSE_HOST}:${LANGFUSE_PORT}"

# 2. Generate Random Trace ID (16 bytes = 32 hex) and Span ID (8 bytes = 16 hex)
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
START_TIME_NANO="$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1e9))')"
END_TIME_NANO="$((START_TIME_NANO + 100000000))"

echo "=========================================================================="
echo " Stage 1: Connectivity Test - Pure OTLP HTTP Ingestion (curl)"
echo " Target Langfuse: $LANGFUSE_URL"
echo " Trace ID:        $TRACE_ID"
echo " Span ID:         $SPAN_ID"
echo "=========================================================================="

# 3. POST OpenTelemetry JSON Payload to Langfuse OTLP Endpoint
OTLP_ENDPOINT="${LANGFUSE_URL}/api/public/otel/v1/traces"

echo "==> Sending OTLP trace to $OTLP_ENDPOINT..."
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${LANGFUSE_PUB}:${LANGFUSE_SEC}" \
  -H "Content-Type: application/json" \
  -H "x-langfuse-ingestion-version: 4" \
  -X POST "$OTLP_ENDPOINT" \
  -d "{
    \"resourceSpans\": [
      {
        \"resource\": {
          \"attributes\": [
            {\"key\": \"service.name\", \"value\": {\"stringValue\": \"sandbox-curl-test\"}}
          ]
        },
        \"scopeSpans\": [
          {
            \"scope\": {\"name\": \"test-connectivity-curl-scope\"},
            \"spans\": [
              {
                \"traceId\": \"${TRACE_ID}\",
                \"spanId\": \"${SPAN_ID}\",
                \"name\": \"manual_otlp_curl_span\",
                \"kind\": 1,
                \"startTimeUnixNano\": \"${START_TIME_NANO}\",
                \"endTimeUnixNano\": \"${END_TIME_NANO}\",
                \"status\": {\"code\": 1}
              }
            ]
          }
        ]
      }
    ]
  }")"

echo "==> OTLP Ingestion HTTP Response: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
    echo "[ERROR] OTLP POST failed with HTTP $HTTP_CODE" >&2
    exit 1
fi

echo "==> Waiting 2s for background queue processing into ClickHouse..."
sleep 2

# 4. Query Langfuse API to Verify Trace
echo "==> Querying Langfuse Observations v2 API for Trace ID: $TRACE_ID..."
QUERY_URL="${LANGFUSE_URL}/api/public/v2/observations?traceId=${TRACE_ID}"

RESPONSE="$(curl -s -u "${LANGFUSE_PUB}:${LANGFUSE_SEC}" "$QUERY_URL")"

if command -v jq >/dev/null 2>&1; then
    echo "$RESPONSE" | jq .
else
    echo "$RESPONSE" | python3 -m json.tool
fi

if echo "$RESPONSE" | grep -q "$TRACE_ID"; then
    echo ""
    echo "=========================================================================="
    echo " [SUCCESS] Trace $TRACE_ID verified in Langfuse!"
    echo "=========================================================================="
else
    echo ""
    echo "[FAIL] Trace ID not found in Langfuse response." >&2
    exit 1
fi
