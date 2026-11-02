#!/usr/bin/env bash
# ==============================================================================
# get_active_agy_session.sh - Auto-Detect Active agy Session & Langfuse IDs
# ==============================================================================
# Discovers Project ID, Session ID, and Trace ID (runId) directly from:
#   1. Langfuse API keys in .env (via GET /api/public/projects) -> Project ID
#   2. Active running agy process lock (via lsof/presence)       -> Session ID
#   3. Canonical unhyphenated OTel 32-hex mapping               -> Trace ID (runId)
#
# Does NOT parse chat history, old transcripts, or previous messages.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Load Environment & API Keys
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
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
fi

LANGFUSE_PUB="${LANGFUSE_PUBLIC_KEY_AGY:-${LANGFUSE_PUBLIC_KEY:-}}"
LANGFUSE_SEC="${LANGFUSE_SECRET_KEY_AGY:-${LANGFUSE_SECRET_KEY:-}}"
HOST_IP="${HOST_IP:-$(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "127.0.0.1")}"
LANGFUSE_PORT="${LANGFUSE_UI_PORT:-3100}"

# Auto-resolve host if loopback is not listening inside sandbox
LANGFUSE_HOST="${LANGFUSE_CONNECT_IP:-$HOST_IP}"
if [ "$LANGFUSE_HOST" = "127.0.0.1" ] || [ "$LANGFUSE_HOST" = "localhost" ]; then
    if ! curl -s --connect-timeout 0.5 "http://${LANGFUSE_HOST}:${LANGFUSE_PORT}/api/public/health" >/dev/null 2>&1; then
        LANGFUSE_HOST="$HOST_IP"
    fi
fi

if [ -z "$LANGFUSE_PUB" ] || [ -z "$LANGFUSE_SEC" ]; then
    echo "[ERROR] Langfuse API keys not found in environment or .env" >&2
    exit 1
fi

# 2. Get Project ID from Langfuse API using the API Key (No history needed!)
PROJECT_ID="$(curl -s -u "${LANGFUSE_PUB}:${LANGFUSE_SEC}" "http://${LANGFUSE_HOST}:${LANGFUSE_PORT}/api/public/projects" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    projects = d.get("data", [])
    if projects:
        print(projects[0].get("id", ""))
except Exception:
    pass
' || true)"

if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID="${LANGFUSE_PROJECT_ID:-}"
fi

# 3. Detect Session ID from the Newly Started / Active agy Session Lock
# (agy creates a real-time presence lock on startup: ~/.gemini/antigravity-cli/presence/<conversationId>.lock)
ACTIVE_PID="$(pgrep -n agy 2>/dev/null || true)"
SESSION_ID=""

if [ -n "$ACTIVE_PID" ]; then
    SESSION_ID="$(lsof -p "$ACTIVE_PID" 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.lock' | sed 's/\.lock$//' | head -n 1 || true)"
fi

# Fallback: check the latest lock file created in presence directory
if [ -z "$SESSION_ID" ]; then
    SESSION_ID="$(ls -t "$HOME/.gemini/antigravity-cli/presence/"*.lock 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null | sed 's/\.lock$//' || true)"
fi

if [ -z "$SESSION_ID" ]; then
    echo "[ERROR] No active agy session detected in memory or ~/.gemini/antigravity-cli/presence/." >&2
    echo "        Please start an agy session first (e.g., 'agy' or 'agy --dangerously-skip-permissions')." >&2
    exit 1
fi

# 4. Derive Trace ID (runId) by stripping hyphens (128-bit OTel hex)
CLEAN_TRACE_ID="$(echo "$SESSION_ID" | tr -d '-' | tr '[:upper:]' '[:lower:]')"

# 5. Output Results
BASE_URL="http://${LANGFUSE_HOST}:${LANGFUSE_PORT}"

echo "=========================================================================="
echo " Active Antigravity Session & Langfuse Telemetry Mapping"
echo "=========================================================================="
if [ -n "$PROJECT_ID" ]; then
    echo " Project ID:        $PROJECT_ID"
fi
echo " Session ID:        $SESSION_ID"
echo " Trace ID (runId):  $CLEAN_TRACE_ID"
echo " Host / Port:       ${LANGFUSE_HOST}:${LANGFUSE_PORT}"
if [ -n "$ACTIVE_PID" ]; then
    echo " Active agy PID:    $ACTIVE_PID"
fi
echo "=========================================================================="
echo ""
if [ -n "$PROJECT_ID" ]; then
    echo " 1. Live Trace View (Graph / Gantt Mode):"
    echo "    ${BASE_URL}/project/${PROJECT_ID}/traces/${CLEAN_TRACE_ID}?traceId=${CLEAN_TRACE_ID}&view=graph"
    echo ""
    echo " 2. Live Session View (All turns in this session):"
    echo "    ${BASE_URL}/project/${PROJECT_ID}/sessions/${SESSION_ID}"
else
    echo " 1. Live Trace View (Direct traceId lookup):"
    echo "    ${BASE_URL}/traces/${CLEAN_TRACE_ID}"
fi
echo "=========================================================================="
