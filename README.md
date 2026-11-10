# local-infra

Shared platform and observability infrastructure for local development across AI and application repositories.

## Overview

Instead of bundling shared infrastructure stacks inside individual application repositories, `local-infra` provides decoupled, independently managed services for local development.

| Service | Path | Host Ports | Purpose |
|---|---|---|---|
| **Langfuse** (v4) | `langfuse/` | Web UI / OTLP: `:3100`, MinIO: `:9090` | LLM observability, tracing, dataset curation & evals |
| **HyperDX** | `hyperdx/` | Web UI: `:8088`, OTLP HTTP: `:4318`, gRPC: `:4317`, ClickHouse: `:8123` / `:9000` | OpenTelemetry distributed tracing and log aggregation |
| **Gitea** | `gitea/` | Web UI: `:3200`, SSH: `:2222` | Local GitHub repository mirror & timestamped immutable backup server |

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

## Quick Start (Gitea Backup Server)

```bash
cd gitea
cp .env.example .env
bash scripts/run_gitea.sh
bash scripts/backup_gitea.sh
```

## Local CI/CD with `act`

To run the GitHub Actions CI workflow locally and validate changes against branch protection rules before pushing:

```bash
# Build the minimal runner image
docker build -t local-infra-runner:latest -f .github/act/Dockerfile .

# Execute CI locally
act workflow_dispatch -W .github/workflows/ci.yml
```

See [docs/runbook_local_act_ci.md](docs/runbook_local_act_ci.md) for full documentation, job isolation, and git hook setup.
