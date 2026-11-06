#!/usr/bin/env bash
# Smoke test for local-infra HyperDX stack
# Verifies container health, Web UI availability, ClickHouse readiness, and OTLP ingestion endpoints.
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
: "${HYPERDX_CONNECT_IP:?HYPERDX_CONNECT_IP must be set in .env}"
: "${HYPERDX_OTLP_HTTP_PORT:?HYPERDX_OTLP_HTTP_PORT must be set in .env}"
: "${HYPERDX_CLICKHOUSE_HTTP_PORT:?HYPERDX_CLICKHOUSE_HTTP_PORT must be set in .env}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"

UI_URL="http://${HYPERDX_CONNECT_IP}:${HYPERDX_UI_PORT}"
GRAFANA_URL="http://${HYPERDX_CONNECT_IP}:${GRAFANA_PORT}"
CH_URL="http://${HYPERDX_CONNECT_IP}:${HYPERDX_CLICKHOUSE_HTTP_PORT}"
OTLP_URL="http://${HYPERDX_CONNECT_IP}:${HYPERDX_OTLP_HTTP_PORT}"

echo "=========================================================="
echo " Running HyperDX + Grafana Smoke Tests"
echo " Target HyperDX UI: $UI_URL"
echo " Target Grafana UI: $GRAFANA_URL"
echo " Target OTLP HTTP:  $OTLP_URL"
echo " Target ClickHouse: $CH_URL"
echo "=========================================================="

echo "=== 0. Verifying Compose & .env Hash State ==="
for STACK_DIR in "$SERVICE_DIR" "$REPO_ROOT/grafana"; do
  STACK_NAME="$(basename "$STACK_DIR")"
  CURRENT_HASH="$(compute_stack_hash "$STACK_DIR")"
  echo "  [$STACK_NAME sha256]: $CURRENT_HASH"
  if [ -f "$STACK_DIR/.compose.sha256" ]; then
    SAVED_HASH="$(cat "$STACK_DIR/.compose.sha256" 2>/dev/null || true)"
    if [ "$CURRENT_HASH" != "$SAVED_HASH" ]; then
      echo "  WARNING: $STACK_NAME Compose/.env changed since last startup ($SAVED_HASH -> $CURRENT_HASH). Re-applying stack..."
      compose_up_smart "$STACK_DIR" --
    else
      echo "  [$STACK_NAME hash-check]: Matches active stack state (.compose.sha256)"
    fi
  fi
done

echo ""
echo "=== 1. Checking Container Health ==="
for CONTAINER_NAME in "hyperdx" "grafana"; do
  STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not running")
  echo "  [$CONTAINER_NAME status]: $STATUS"
  if [[ "$STATUS" != "running" ]]; then
    echo "ERROR: Container $CONTAINER_NAME is not running (status: $STATUS)" >&2
    exit 1
  fi
done

CONTAINER_NAME="hyperdx"

HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
echo "  [$CONTAINER_NAME health]: $HEALTH"
if [[ "$HEALTH" != "healthy" && "$HEALTH" != "none" ]]; then
  # Give it a short grace period if still starting
  if [[ "$HEALTH" == "starting" ]]; then
    echo "  Container is still starting, waiting up to 15s for health check..."
    for _ in {1..15}; do
      sleep 1
      HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
      if [[ "$HEALTH" == "healthy" ]]; then break; fi
    done
  fi
  if [[ "$HEALTH" != "healthy" ]]; then
    echo "ERROR: Container $CONTAINER_NAME is not healthy (health: $HEALTH)" >&2
    exit 1
  fi
fi

echo ""
echo "=== 2. Checking Web UI Endpoints (HyperDX & Grafana) ==="
UI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$UI_URL" || echo "failed")
echo "  GET $UI_URL -> HTTP $UI_STATUS"
if [[ "$UI_STATUS" != "200" ]]; then
  echo "ERROR: HyperDX Web UI check failed with HTTP $UI_STATUS (expected 200)" >&2
  exit 1
fi

GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GRAFANA_URL/api/health" || echo "failed")
echo "  GET $GRAFANA_URL/api/health -> HTTP $GRAFANA_STATUS"
if [[ "$GRAFANA_STATUS" != "200" ]]; then
  echo "ERROR: Grafana health check failed with HTTP $GRAFANA_STATUS (expected 200)" >&2
  exit 1
fi

echo ""
echo "=== 3. Checking ClickHouse HTTP API ==="
CH_PING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$CH_URL/ping" || echo "failed")
echo "  GET $CH_URL/ping -> HTTP $CH_PING_STATUS"
if [[ "$CH_PING_STATUS" != "200" ]]; then
  echo "ERROR: ClickHouse ping failed with HTTP $CH_PING_STATUS" >&2
  exit 1
fi

CH_PING_BODY=$(curl -s "$CH_URL/ping" || echo "")
if [[ "$CH_PING_BODY" != "Ok."* ]]; then
  echo "ERROR: ClickHouse ping body unexpected: '$CH_PING_BODY'" >&2
  exit 1
fi

CH_QUERY_RES=$(curl -s "$CH_URL/?query=SELECT%201" || echo "failed")
echo "  SELECT 1 query result: $CH_QUERY_RES"
if [[ "$CH_QUERY_RES" != "1"* ]]; then
  echo "ERROR: ClickHouse query check failed" >&2
  exit 1
fi

echo ""
echo "=== 4. Checking OTLP Trace Ingestion Endpoint ==="
OTLP_TRACES_STATUS="failed"
for _ in {1..15}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"resourceSpans":[]}' \
    "$OTLP_URL/v1/traces" || echo "failed")
  if [[ "$CODE" == "200" ]]; then
    OTLP_TRACES_STATUS="$CODE"
    break
  fi
  sleep 1
done
echo "  POST $OTLP_URL/v1/traces -> HTTP $OTLP_TRACES_STATUS"
if [[ "$OTLP_TRACES_STATUS" != "200" ]]; then
  echo "ERROR: OTLP traces ingestion failed with HTTP $OTLP_TRACES_STATUS (expected 200)" >&2
  exit 1
fi

echo ""
echo "=== 5. Checking OTLP Log Ingestion Endpoint ==="
OTLP_LOGS_STATUS="failed"
for _ in {1..15}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"resourceLogs":[]}' \
    "$OTLP_URL/v1/logs" || echo "failed")
  if [[ "$CODE" == "200" ]]; then
    OTLP_LOGS_STATUS="$CODE"
    break
  fi
  sleep 1
done
echo "  POST $OTLP_URL/v1/logs -> HTTP $OTLP_LOGS_STATUS"
if [[ "$OTLP_LOGS_STATUS" != "200" ]]; then
  echo "ERROR: OTLP logs ingestion failed with HTTP $OTLP_LOGS_STATUS (expected 200)" >&2
  exit 1
fi

echo ""
echo "=========================================================="
echo " SUCCESS: All HyperDX + Grafana smoke tests passed!"
echo " HyperDX UI:  $UI_URL"
echo " Grafana UI:  $GRAFANA_URL"
echo " OTLP Ingest: $OTLP_URL"
echo " ClickHouse:  $CH_URL"
echo "=========================================================="
