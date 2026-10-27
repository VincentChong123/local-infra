#!/usr/bin/env bash
# Start the local HyperDX stack (Web UI + OTel Collector + ClickHouse + Mongo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SERVICE_DIR"

# SSOT: local .env in hyperdx/ directory
ENV_FILE="$SERVICE_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE (copy .env.example)"; exit 1; }
set -a; . "$ENV_FILE"; set +a

: "${HYPERDX_UI_PORT:?HYPERDX_UI_PORT must be set in .env}"
: "${HYPERDX_LISTEN_IP:?HYPERDX_LISTEN_IP must be set in .env}"
: "${HYPERDX_CONNECT_IP:?HYPERDX_CONNECT_IP must be set in .env}"
: "${HYPERDX_OTLP_HTTP_PORT:?HYPERDX_OTLP_HTTP_PORT must be set in .env}"
: "${HYPERDX_OTLP_GRPC_PORT:?HYPERDX_OTLP_GRPC_PORT must be set in .env}"
: "${HYPERDX_CLICKHOUSE_HTTP_PORT:?HYPERDX_CLICKHOUSE_HTTP_PORT must be set in .env}"
: "${TZ:?TZ must be set in .env}"

UI_PORT="$HYPERDX_UI_PORT"
CONNECT_IP="$HYPERDX_CONNECT_IP"

echo "=== Starting HyperDX from local-infra ==="
docker compose up -d "$@"

echo "Waiting for HyperDX Web UI on http://${CONNECT_IP}:${UI_PORT} ..."
READY=0
for _ in {1..60}; do
  if curl -s -f "http://${CONNECT_IP}:${UI_PORT}" > /dev/null 2>&1; then
    echo "HyperDX is ready!"
    READY=1
    break
  fi
  sleep 2
  printf "."
done

if [ "$READY" -ne 1 ]; then
  echo ""
  echo "ERROR: HyperDX Web UI failed to become healthy within 120 seconds." >&2
  exit 1
fi

echo ""
echo "=========================================================="
echo " HyperDX Observability Stack Running (local-infra)"
echo "=========================================================="
echo " - Web UI:        http://${CONNECT_IP}:${UI_PORT}"
echo " - OTLP HTTP:     http://${CONNECT_IP}:${HYPERDX_OTLP_HTTP_PORT} (POST /v1/traces, POST /v1/logs)"
echo " - OTLP gRPC:     http://${CONNECT_IP}:${HYPERDX_OTLP_GRPC_PORT}"
echo " - ClickHouse:    http://${CONNECT_IP}:${HYPERDX_CLICKHOUSE_HTTP_PORT}"
echo "=========================================================="
echo "Client integration settings for consuming repositories:"
echo "  OTEL_EXPORTER_OTLP_ENDPOINT=http://${CONNECT_IP}:${HYPERDX_OTLP_HTTP_PORT}   # (or http://host.docker.internal:${HYPERDX_OTLP_HTTP_PORT} from Docker)"
echo "  OTEL_EXPORTER_OTLP_HEADERS="
echo "=========================================================="
echo "Run smoke tests: bash scripts/test_hyperdx.sh"
echo "=========================================================="
