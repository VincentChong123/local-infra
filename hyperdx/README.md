# HyperDX Local Observability Stack

Decoupled, local all-in-one OpenTelemetry collector, ClickHouse storage, and search UI for local development across multiple services and repositories.

## Service URLs & Ports

| Component | Host Port | Internal Container Port | Description |
|---|---|---|---|
| **HyperDX Web UI** | `8088` | `8080` | Search dashboard ([http://localhost:8088](http://localhost:8088)) |
| **OTEL OTLP HTTP** | `4318` | `4318` | Ingests `POST /v1/traces` & `POST /v1/logs` |
| **OTEL OTLP gRPC** | `4317` | `4317` | Ingests gRPC telemetry |
| **ClickHouse HTTP** | `8123` | `8123` | ClickHouse query API |
| **ClickHouse Native**| `9000` | `9000` | ClickHouse native TCP client |

> **Port 8088:** We map the Web UI to host port `8088` by default so it does not conflict with common application ports (e.g., `8080`).

---

## Quick Start

```bash
cd hyperdx
cp .env.example .env
bash scripts/run_hyperdx.sh
```

### Running Smoke Tests

Verify that the stack is healthy and ready to ingest traces and logs:

```bash
bash scripts/test_hyperdx.sh
```

### Stopping or Resetting

```bash
# Stop containers (preserves volumes)
docker compose down

# Reset containers and delete all telemetry data
docker compose down -v
```

---

## Client Integration Guide

Any local service or repository can send OpenTelemetry traces and logs to this HyperDX instance.

### For Applications Running Inside Docker (e.g. `doc-micro-access-ctr` containers)

```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318
OTEL_EXPORTER_OTLP_HEADERS=
```

Ensure the client service container has `host.docker.internal` mapped in its compose file:
```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### For Applications Running Directly on the Host Machine

```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_HEADERS=
```

---

## ClickHouse Connection & Preconfigured Sources

HyperDX runs an embedded ClickHouse instance automatically mapped with persistent volumes:
- Volume `hyperdx_clickhouse_data`: ClickHouse storage
- Volume `hyperdx_mongo_data`: HyperDX metadata storage

Preconfigured connections and sources (`otel_logs` and `otel_traces`) are injected directly via `DEFAULT_CONNECTIONS` and `DEFAULT_SOURCES` environment variables in `hyperdx.compose.yaml`, so no manual browser onboarding wizard is required.
