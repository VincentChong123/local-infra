#!/usr/bin/env bash
# ==============================================================================
# test_smoke.sh - Stage 2: Antigravity OTel Exporter Pipeline Smoke Test
# ==============================================================================
# Sends a synthetic Antigravity Stop event via `export_agy_otel` and verifies
# that the span (traceId) is stored in Langfuse via the Observations v2 API.
# Tests wrapper, Python venv, and OTel serialization ($0 LLM cost).
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

# 2. Generate Unique Conversation ID & Trace ID
TEST_UUID="$(python3 -c 'import uuid; print(str(uuid.uuid4()))')"
CLEAN_TRACE_ID="$(echo "$TEST_UUID" | tr -d '-')"

echo "=========================================================================="
echo " Stage 2: Smoke Test - Antigravity Exporter Pipeline (export_agy_otel)"
echo " Target Langfuse: $LANGFUSE_URL"
echo " Test Session:    $TEST_UUID"
echo " OTel Trace ID:   $CLEAN_TRACE_ID"
echo "=========================================================================="

# 3. Emit Dummy Stop Event through export_agy_otel
PAYLOAD="{\"terminationReason\":\"completed\",\"conversationId\":\"$TEST_UUID\",\"modelName\":\"dummy-test-agent\"}"

echo "==> Sending dummy Antigravity Stop hook payload..."
if command -v export_agy_otel >/dev/null 2>&1; then
    echo "$PAYLOAD" | export_agy_otel
elif [ -x "${SCRIPT_DIR}/export_agy_otel.sh" ]; then
    echo "$PAYLOAD" | "${SCRIPT_DIR}/export_agy_otel.sh"
elif [ -x "$HOME/.gemini/antigravity-cli/scripts/export_agy_otel.sh" ]; then
    echo "$PAYLOAD" | "$HOME/.gemini/antigravity-cli/scripts/export_agy_otel.sh"
else
    echo "[ERROR] export_agy_otel not found in PATH, script directory, or ~/.gemini/antigravity-cli/scripts/" >&2
    exit 1
fi

echo "==> Waiting 1s for Langfuse ingestion..."
sleep 1

# 4. Query Langfuse API to Verify Trace
echo "==> Querying Langfuse Observations v2 API for Trace ID: $CLEAN_TRACE_ID..."
QUERY_URL="${LANGFUSE_URL}/api/public/v2/observations?traceId=${CLEAN_TRACE_ID}"

RESPONSE="$(curl -s -u "${LANGFUSE_PUB}:${LANGFUSE_SEC}" "$QUERY_URL")"

if command -v jq >/dev/null 2>&1; then
    echo "$RESPONSE" | jq .
else
    echo "$RESPONSE" | python3 -m json.tool
fi

if echo "$RESPONSE" | grep -q "$CLEAN_TRACE_ID"; then
    echo ""
    echo "=========================================================================="
    echo " [SUCCESS] Trace $CLEAN_TRACE_ID verified in Langfuse!"
    echo "=========================================================================="
else
    echo ""
    echo "[FAIL] Trace ID not found in Langfuse response." >&2
    exit 1
fi
