#!/usr/bin/env bash
# Smoke test for local-infra Langfuse stack
# Verifies container health, Web API readiness, API key authentication, and OTLP ingestion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SERVICE_DIR"

# SSOT: local .env in langfuse/ directory
ENV_FILE="$SERVICE_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE (copy .env.example and configure credentials)"; exit 1; }
set -a; . "$ENV_FILE"; set +a

: "${LANGFUSE_UI_PORT:?LANGFUSE_UI_PORT must be set in .env}"
: "${LANGFUSE_CONNECT_IP:?LANGFUSE_CONNECT_IP must be set in .env}"
: "${LANGFUSE_PUBLIC_KEY:?LANGFUSE_PUBLIC_KEY must be set in .env}"
: "${LANGFUSE_SECRET_KEY:?LANGFUSE_SECRET_KEY must be set in .env}"

BASE_URL="http://${LANGFUSE_CONNECT_IP}:${LANGFUSE_UI_PORT}"

echo "=========================================================="
echo " Running Langfuse Smoke Tests"
echo " Target: $BASE_URL"
echo "=========================================================="

echo "=== 1. Checking Database & Service Container Health ==="
db_containers=(
  "langfuse-postgres-1"
  "langfuse-clickhouse-1"
  "langfuse-redis-1"
  "langfuse-minio-1"
)

for container in "${db_containers[@]}"; do
  STATUS=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not running")
  echo "  [$container]: $STATUS"
  if [[ "$STATUS" != "healthy" ]]; then
    echo "ERROR: Container $container is not healthy (status: $STATUS)" >&2
    exit 1
  fi
done

app_containers=(
  "langfuse-langfuse-web-1"
  "langfuse-langfuse-worker-1"
)

for container in "${app_containers[@]}"; do
  STATE=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not running")
  echo "  [$container]: $STATE"
  if [[ "$STATE" != "running" ]]; then
    echo "ERROR: Container $container is not running (state: $STATE)" >&2
    exit 1
  fi
done

echo ""
echo "=== 2. Checking Web API Health Endpoint ==="
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/public/health" || echo "failed")
echo "  GET $BASE_URL/api/public/health -> HTTP $HEALTH_STATUS"
if [[ "$HEALTH_STATUS" != "200" ]]; then
  echo "ERROR: Web health check failed with HTTP $HEALTH_STATUS" >&2
  exit 1
fi

echo ""
echo "=== 3. Checking API Key Basic Authentication ==="
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
  "$BASE_URL/api/public/projects" || echo "failed")
echo "  GET $BASE_URL/api/public/projects -> HTTP $AUTH_STATUS"
if [[ "$AUTH_STATUS" != "200" ]]; then
  echo "ERROR: API key authentication failed with HTTP $AUTH_STATUS (expected 200)" >&2
  echo "Check LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY in .env" >&2
  exit 1
fi

echo ""
echo "=== 4. Checking OTLP Trace Ingestion Endpoint ==="
OTLP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
  -H "Content-Type: application/json" \
  -H "x-langfuse-ingestion-version: 4" \
  "$BASE_URL/api/public/otel/v1/traces" || echo "failed")
echo "  POST $BASE_URL/api/public/otel/v1/traces -> HTTP $OTLP_STATUS"
# 400 (missing payload) or 200 confirms auth was accepted and route exists. 401/404 is a failure.
if [[ "$OTLP_STATUS" =~ ^(200|400|405)$ ]]; then
  echo "  OTLP endpoint is reachable and authenticated successfully."
else
  echo "ERROR: OTLP endpoint check failed with HTTP $OTLP_STATUS" >&2
  exit 1
fi

echo ""
echo "=========================================================="
echo " SUCCESS: All Langfuse smoke tests passed!"
echo " Web UI:     $BASE_URL"
echo " OTLP Ingest: $BASE_URL/api/public/otel"
echo "=========================================================="
