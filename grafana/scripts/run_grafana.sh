#!/usr/bin/env bash
# Start the local Grafana stack with shared config/.env hash checking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVICE_DIR/.." && pwd)"
cd "$SERVICE_DIR"

# Load shared hash-checking routine (shared across grafana, hyperdx, and langfuse)
# shellcheck source=../../scripts/compose_hash.sh
source "$REPO_ROOT/scripts/compose_hash.sh"

# SSOT: local .env in grafana/ directory
ENV_FILE="$SERVICE_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a

CONNECT_IP="${GRAFANA_CONNECT_IP:-127.0.0.1}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"

# Ensure bind-mounted data directory exists and is writable by container user (1000:1000)
mkdir -p "$SERVICE_DIR/data"

echo "=== Starting Grafana from local-infra ==="
compose_up_smart "$SERVICE_DIR" -- "$@"

echo "Waiting for Grafana Web UI on http://${CONNECT_IP}:${GRAFANA_PORT}/api/health ..."
READY=0
for _ in {1..30}; do
  if curl -s -f "http://${CONNECT_IP}:${GRAFANA_PORT}/api/health" > /dev/null 2>&1; then
    echo "Grafana Web UI is ready!"
    READY=1
    break
  fi
  sleep 2
  printf "."
done

if [ "$READY" -ne 1 ]; then
  echo ""
  echo "ERROR: Grafana Web UI failed to become healthy within 60 seconds." >&2
  exit 1
fi

echo ""
echo "=========================================================="
echo " Grafana Running (local-infra)"
echo "=========================================================="
echo " - Web UI:     http://${CONNECT_IP}:${GRAFANA_PORT} (login: ${GF_SECURITY_ADMIN_USER})"
echo " - Datasource: HyperDX ClickHouse (host.docker.internal:9000)"
echo "=========================================================="
