# HyperDX All-in-One Local Container
# Builds on the official HyperDX local all-in-one image (ClickHouse + Mongo + OTel Collector + UI)
# Reference: https://github.com/hyperdxio/hyperdx/tree/main/docker/hyperdx
FROM ghcr.io/hyperdxio/hyperdx-local:2-beta

LABEL org.opencontainers.image.title="HyperDX Local Observability Stack" \
      org.opencontainers.image.description="Decoupled local OpenTelemetry trace and log collector for services" \
      org.opencontainers.image.vendor="HyperDX"

ENV NODE_ENV=production \
    HYPERDX_APP_URL=http://localhost:8088 \
    FRONTEND_URL=http://localhost:8088 \
    HYPERDX_API_PORT=8000 \
    HYPERDX_APP_PORT=8080 \
    HYPERDX_LOG_LEVEL=info \
    USAGE_STATS_ENABLED=false

# Expose standard endpoints:
# 8080: HyperDX Web UI internal
# 4318: OTLP HTTP receiver
# 4317: OTLP gRPC receiver
# 8123: ClickHouse HTTP interface
# 9000: ClickHouse Native TCP
# 13133: Healthcheck extension
EXPOSE 8080 4318 4317 8123 9000 13133
