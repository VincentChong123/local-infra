#!/usr/bin/env bash
# Start the local HyperDX stack (Web UI + OTel Collector + ClickHouse + Mongo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/.." && pwd)"
cd "$SERVICE_DIR"

# Load shared hash-checking routine (shared across grafana, hyperdx, and langfuse)
# shellcheck source=../../scripts/compose_hash.sh
source "$REPO_ROOT/scripts/compose_hash.sh"

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
compose_up_smart "$SERVICE_DIR" -- "$@"

echo "Waiting for HyperDX Web UI on http://${CONNECT_IP}:${UI_PORT} ..."
READY=0
for _ in {1..60}; do
  if curl -s -f "http://${CONNECT_IP}:${UI_PORT}" > /dev/null 2>&1; then
    echo "HyperDX Web UI is ready!"
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

echo "Waiting for HyperDX OTLP HTTP receiver on http://${CONNECT_IP}:${HYPERDX_OTLP_HTTP_PORT}/v1/traces ..."
OTLP_READY=0
for _ in {1..30}; do
  if curl -s -o /dev/null -X POST -H "Content-Type: application/json" -d '{"resourceSpans":[]}' "http://${CONNECT_IP}:${HYPERDX_OTLP_HTTP_PORT}/v1/traces" 2>/dev/null; then
    echo "HyperDX OTLP receiver is ready!"
    OTLP_READY=1
    break
  fi
  sleep 2
  printf "."
done

if [ "$OTLP_READY" -ne 1 ]; then
  echo ""
  echo "ERROR: HyperDX OTLP receiver failed to become ready within 60 seconds." >&2
  exit 1
fi

GRAFANA_PORT="${GRAFANA_PORT:-3001}"
echo ""
bash "$REPO_ROOT/grafana/scripts/run_grafana.sh" "$@"

echo ""
echo "=========================================================="
echo " HyperDX + Grafana Observability Stack Running (local-infra)"
echo "=========================================================="
echo " - HyperDX UI:    http://${CONNECT_IP}:${UI_PORT}"
echo " - Grafana UI:    http://${CONNECT_IP}:${GRAFANA_PORT}"
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
