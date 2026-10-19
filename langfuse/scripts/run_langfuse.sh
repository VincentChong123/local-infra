#!/usr/bin/env bash
# Start the local Langfuse v4 stack (web UI + worker + Postgres/ClickHouse/Redis/MinIO).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SERVICE_DIR"

# SSOT: local .env in langfuse/ directory
ENV_FILE="$SERVICE_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE (copy .env.example and configure credentials)"; exit 1; }
set -a; . "$ENV_FILE"; set +a

: "${LANGFUSE_UI_PORT:?LANGFUSE_UI_PORT must be set in .env}"
: "${LANGFUSE_LISTEN_IP:?LANGFUSE_LISTEN_IP must be set in .env}"
: "${LANGFUSE_CONNECT_IP:?LANGFUSE_CONNECT_IP must be set in .env}"
: "${LANGFUSE_INIT_USER_EMAIL:?LANGFUSE_INIT_USER_EMAIL must be set in .env}"
: "${LANGFUSE_PUBLIC_KEY:?LANGFUSE_PUBLIC_KEY must be set in .env}"

UI_PORT="$LANGFUSE_UI_PORT"
CONNECT_IP="$LANGFUSE_CONNECT_IP"

echo "=== Starting Langfuse (v4) from local-infra ==="
docker compose up -d "$@"

echo "Waiting for Langfuse web on http://${CONNECT_IP}:${UI_PORT} (first start runs DB migrations, can take a few minutes) ..."
READY=0
for _ in {1..90}; do
  if curl -s -f "http://${CONNECT_IP}:${UI_PORT}/api/public/health" > /dev/null 2>&1; then
    echo "Langfuse is ready!"
    READY=1
    break
  fi
  sleep 3
  printf "."
done

if [ "$READY" -ne 1 ]; then
  echo ""
  echo "ERROR: Langfuse web failed to become healthy within 270 seconds." >&2
  exit 1
fi

echo ""
echo "=========================================================="
echo " Langfuse Running (local-infra)"
echo "=========================================================="
echo " - Web UI:  http://${CONNECT_IP}:${UI_PORT}  (login: ${LANGFUSE_INIT_USER_EMAIL})"
echo " - OTLP:    http://${CONNECT_IP}:${UI_PORT}/api/public/otel (HTTP only)"
echo "=========================================================="
echo "Client integration settings for consuming repositories:"
echo "  IS_LANGFUSE_ENABLED=true"
echo "  LANGFUSE_SERVER_URL=http://${CONNECT_IP}:${UI_PORT}   # (or host.docker.internal:${UI_PORT} from Docker)"
echo "  LANGFUSE_PUBLIC_KEY=${LANGFUSE_PUBLIC_KEY}"
echo "  LANGFUSE_SECRET_KEY=<see .env>"
echo "=========================================================="
echo "Run smoke tests: bash scripts/test_langfuse.sh"
echo "=========================================================="
