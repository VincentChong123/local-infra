# local-infra

Shared platform and observability infrastructure for local development across AI and application repositories.

## Overview

Instead of bundling shared infrastructure stacks inside individual application repositories, `local-infra` provides decoupled, independently managed services for local development.

| Service | Path | Host Ports | Purpose |
|---|---|---|---|
| **Langfuse** (v4) | `langfuse/` | Web UI / OTLP: `:3100`, MinIO: `:9090` | LLM observability, tracing, dataset curation & evals |
| **HyperDX** | `hyperdx/` | Web UI: `:8088`, OTLP HTTP: `:4318`, gRPC: `:4317`, ClickHouse: `:8123` / `:9000` | OpenTelemetry distributed tracing and log aggregation |

## Conventions

1. **Modular Subservices**: Each directory (e.g. `langfuse/`) is fully self-contained with its own `docker-compose.yaml`, `run_<service>.sh` script, `.env.example`, and `.env`.
2. **Secrets & SSOT**:
   - Environment variables are defined per-service in `<service>/.env` (derived from `<service>/.env.example`).
   - `.env` files are strictly gitignored (`**/.env`).
   - All defaults are set in `.env` (no silent code or compose fallbacks).
3. **Port Conflict Avoidance**:
   - Ports are assigned to avoid clashing with common development ports (e.g., API gateway on 3000, app Redis on 6379, app Postgres on 5432).
4. **Volume Persistence**:
   - Compose project names and volume declarations are configured to ensure persistence across restarts.

## Quick Start (Langfuse)

```bash
cd langfuse
cp .env.example .env    # configure credentials if not already present
bash scripts/run_langfuse.sh
```

## Quick Start (HyperDX)

```bash
cd hyperdx
cp .env.example .env
bash scripts/run_hyperdx.sh
```
