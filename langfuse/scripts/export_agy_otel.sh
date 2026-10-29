#!/usr/bin/env bash
# ==============================================================================
# export_agy_otel.sh - Wrapper to execute export_agy_otel_to_langfuse.py
# Strict environment validation (no_env_fallback rule):
# Defaults live ONLY in the root .env. If expected variables are missing, raise error.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_RAW_URL="https://raw.githubusercontent.com/Vincentchong123/local-infra/main/langfuse/scripts"
VERSION_FILE="${SCRIPT_DIR}/.version"

# ------------------------------------------------------------------------------
# 0. On-Demand Update & Version Checking CLI Handlers
# ------------------------------------------------------------------------------
update_self() {
    echo "==> Checking for latest version of export_agy_otel from GitHub..."
    local remote_header
    remote_header="$(curl -sI "${REPO_RAW_URL}/export_agy_otel.sh" 2>/dev/null || true)"
    local remote_etag
    remote_etag="$(echo "$remote_header" | grep -i etag | tr -d '\r"' | awk '{print $2}' || true)"
    local local_etag
    local_etag="$(cat "$VERSION_FILE" 2>/dev/null || echo "")"

    if [ -n "$remote_etag" ] && [ "$remote_etag" = "$local_etag" ]; then
        echo "==> Already up to date (version: ${local_etag:0:8})."
        return 0
    fi

    echo "==> Downloading latest export_agy_otel from GitHub..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if curl -sSL "${REPO_RAW_URL}/export_agy_otel.sh" -o "${tmp_dir}/export_agy_otel.sh" && \
       curl -sSL "${REPO_RAW_URL}/export_agy_otel_to_langfuse.py" -o "${tmp_dir}/export_agy_otel_to_langfuse.py"; then
        chmod +x "${tmp_dir}/export_agy_otel"*
        cp "${tmp_dir}/export_agy_otel.sh" "${SCRIPT_DIR}/export_agy_otel.sh"
        cp "${tmp_dir}/export_agy_otel_to_langfuse.py" "${SCRIPT_DIR}/export_agy_otel_to_langfuse.py"
        [ -n "$remote_etag" ] && echo "$remote_etag" > "$VERSION_FILE"
        rm -rf "$tmp_dir"
        echo "==> Successfully updated export_agy_otel to latest version (${remote_etag:0:8})!"
    else
        rm -rf "$tmp_dir"
        echo "[ERROR] Failed to download updates from GitHub." >&2
        return 1
    fi
}

check_self() {
    echo "==> Checking version against GitHub..."
    local remote_header
    remote_header="$(curl -sI "${REPO_RAW_URL}/export_agy_otel.sh" 2>/dev/null || true)"
    local remote_etag
    remote_etag="$(echo "$remote_header" | grep -i etag | tr -d '\r"' | awk '{print $2}' || true)"
    local local_etag
    local_etag="$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")"

    if [ -z "$remote_etag" ]; then
        echo "[WARNING] Could not reach GitHub to check version." >&2
        return 1
    elif [ "$remote_etag" = "$local_etag" ]; then
        echo "==> Up to date (local: ${local_etag:0:8}, remote: ${remote_etag:0:8})"
    else
        echo "==> Update available! (local: ${local_etag:0:8}, remote: ${remote_etag:0:8})"
        echo "    Run 'export_agy_otel --update' to apply."
    fi
}

if [ "${1:-}" = "--update" ]; then
    update_self
    exit 0
elif [ "${1:-}" = "--check" ]; then
    check_self
    exit 0
elif [ "${1:-}" = "--version" ]; then
    cat "$VERSION_FILE" 2>/dev/null || echo "dev-local"
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. Environment Loading (CWD .env or local-infra langfuse .env as SSOT)
# ------------------------------------------------------------------------------
ENV_FILE="${PWD}/.env"
if [ ! -f "$ENV_FILE" ]; then
    ENV_FILE="${SCRIPT_DIR}/../.env"
fi

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
fi

# ------------------------------------------------------------------------------
# 2. Strict Variable Validation (Fail Fast - No Fallbacks)
# ------------------------------------------------------------------------------
: "${IS_LANGFUSE_ENABLED:?IS_LANGFUSE_ENABLED must be set in .env}"

# If Langfuse export is explicitly disabled, exit immediately
if [ "$IS_LANGFUSE_ENABLED" != "true" ]; then
    echo "{}"
    exit 0
fi

# When enabled, required variables must be explicitly defined
: "${LANGFUSE_UI_PORT:?LANGFUSE_UI_PORT must be set in .env}"
: "${LANGFUSE_CONNECT_IP:?LANGFUSE_CONNECT_IP must be set in .env}"
: "${LANGFUSE_SERVER_URL:?LANGFUSE_SERVER_URL must be set in .env}"

if [ -z "${LANGFUSE_PUBLIC_KEY_AGY:-}" ] && [ -z "${LANGFUSE_PUBLIC_KEY:-}" ]; then
    echo "[export_agy_otel] ERROR: LANGFUSE_PUBLIC_KEY (or LANGFUSE_PUBLIC_KEY_AGY) must be set in .env" >&2
    exit 1
fi

if [ -z "${LANGFUSE_SECRET_KEY_AGY:-}" ] && [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
    echo "[export_agy_otel] ERROR: LANGFUSE_SECRET_KEY (or LANGFUSE_SECRET_KEY_AGY) must be set in .env" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Python Environment Resolution (Strict: No uncapable fallbacks)
# ------------------------------------------------------------------------------
is_otel_capable() {
    local py="$1"
    [ -n "$py" ] && [ -x "$py" ] && "$py" -c "import opentelemetry.exporter.otlp.proto.http.trace_exporter" 2>/dev/null
}

PYTHON=""

# 1. Custom override via AGY_HOOKS_PYTHON
if [ -n "${AGY_HOOKS_PYTHON:-}" ]; then
    if is_otel_capable "$AGY_HOOKS_PYTHON"; then
        PYTHON="$AGY_HOOKS_PYTHON"
    else
        echo "[export_agy_otel] ERROR: AGY_HOOKS_PYTHON is set to '$AGY_HOOKS_PYTHON' but cannot import required opentelemetry modules." >&2
        exit 1
    fi
# 2. Centralized shared venv for Antigravity hooks (preferred)
elif is_otel_capable "$HOME/.gemini/antigravity-cli/hooks_env/.venv/bin/python3"; then
    PYTHON="$HOME/.gemini/antigravity-cli/hooks_env/.venv/bin/python3"
# 3. Project-scoped venvs (if native and valid)
elif is_otel_capable "${PWD}/.venv/bin/python3"; then
    PYTHON="${PWD}/.venv/bin/python3"
elif is_otel_capable "${PWD}/apps/ai_service/.venv/bin/python3"; then
    PYTHON="${PWD}/apps/ai_service/.venv/bin/python3"
# 4. Sandbox guest virtual environments (~/.venv or /var/venv or UV_PROJECT_ENVIRONMENT)
elif [ -n "${UV_PROJECT_ENVIRONMENT:-}" ] && is_otel_capable "${UV_PROJECT_ENVIRONMENT}/bin/python3"; then
    PYTHON="${UV_PROJECT_ENVIRONMENT}/bin/python3"
elif is_otel_capable "$HOME/.venv/bin/python3"; then
    PYTHON="$HOME/.venv/bin/python3"
elif is_otel_capable "/var/venv/bin/python3"; then
    PYTHON="/var/venv/bin/python3"
# 5. System python
elif is_otel_capable "/usr/bin/python3"; then
    PYTHON="/usr/bin/python3"
fi

# FAIL FAST: If no capable python found, raise error (no silent fallback!)
if [ -z "$PYTHON" ]; then
    echo "[export_agy_otel] ERROR: No OpenTelemetry-capable Python runtime found." >&2
    echo "       Expected dedicated hooks venv at: $HOME/.gemini/antigravity-cli/hooks_env/.venv" >&2
    echo "       Or a candidate venv with opentelemetry-sdk and opentelemetry-exporter-otlp-proto-http installed." >&2
    exit 1
fi

# Observability: Print status to stderr so stdout remains pure JSON for Antigravity hooks
echo "[export_agy_otel] Runtime: $PYTHON" >&2

# Detect if stdin is an interactive terminal (manual test execution)
if [ -t 0 ]; then
    echo "[export_agy_otel] Notice: Stdin is an interactive terminal (no input piped)." >&2
    echo "[export_agy_otel] Supplying dummy test payload to prevent blocking." >&2
    TEST_PAYLOAD='{"toolCall":{"name":"manual_terminal_test","args":{"caller":"human"}},"stepIdx":0,"conversationId":"terminal-test"}'
    echo "$TEST_PAYLOAD" | exec "$PYTHON" "$SCRIPT_DIR/export_agy_otel_to_langfuse.py" "$@"
else
    exec "$PYTHON" "$SCRIPT_DIR/export_agy_otel_to_langfuse.py" "$@"
fi
