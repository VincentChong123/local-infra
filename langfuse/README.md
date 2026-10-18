# Langfuse (v4 Self-Hosted)

Centralized LLM observability, tracing, dataset curation, and evaluations for local AI development projects.

## Port Map

| Component | Host Port | Network Scope | Description |
|---|---|---|---|
| Web UI & OTLP | `${LANGFUSE_LISTEN_IP}:${LANGFUSE_UI_PORT}` (`0.0.0.0:3100` / `127.0.0.1:3100`) | Loopback / Host | Web Dashboard & `/api/public/otel` HTTP trace receiver |
| MinIO Console | `127.0.0.1:9090` | Loopback only | S3 event and media blob storage |
| Postgres | 5432 (Internal) | Docker network | Application database (users, projects, API keys, configs) |
| ClickHouse | 8123 / 9000 (Internal) | Docker network | Fast analytical column-store for trace events & observations |
| Redis | 6379 (Internal) | Docker network | Background worker queue & caching |
| Worker | - | Docker network | Asynchronous trace processing & ingestion worker |

*Note: Database and internal service ports are intentionally not published to the host to prevent port collisions with other local databases (e.g. HyperDX ClickHouse 8123/9000, application Redis 6379, or system Postgres 5432).*

---

## Operating Instructions

### 1. Initial Setup
```bash
cp .env.example .env
# Edit .env if customizing ports or default admin credentials
```

### 2. Start the Stack
```bash
bash scripts/run_langfuse.sh
```
This launches all containers and polls the `/api/public/health` endpoint until the stack is ready.

### 3. Run Smoke Tests
```bash
bash scripts/test_langfuse.sh
```
This tests:
1. Container health across Postgres, ClickHouse, Redis, MinIO, Web, and Worker.
2. Web API `/api/public/health` status.
3. API key Basic Auth verification against `/api/public/projects`.
4. OTLP trace ingestion endpoint readiness (`/api/public/otel/v1/traces`).

### 4. Stop or Reset
- **Stop services (preserves all data)**:
  ```bash
  docker compose down
  ```
- **Reset services (permanently deletes all data and volumes)**:
  ```bash
  docker compose down -v
  ```

---

## Connecting Client Applications

To export OpenTelemetry LLM traces from client applications (such as `doc-micro-access-ctr` or `personal_assistant_top`), configure the client's `.env`:

```env
IS_LANGFUSE_ENABLED=true
LANGFUSE_CONNECT_IP=127.0.0.1
LANGFUSE_UI_PORT=3100

# When client runs on the host:
LANGFUSE_SERVER_URL=http://127.0.0.1:3100
LANGFUSE_HOST=http://127.0.0.1:3100

# When client runs inside a Docker container:
# LANGFUSE_SERVER_URL=http://host.docker.internal:3100
# LANGFUSE_HOST=http://host.docker.internal:3100

LANGFUSE_PUBLIC_KEY=<LANGFUSE_PUBLIC_KEY from local-infra/langfuse/.env>
LANGFUSE_SECRET_KEY=<LANGFUSE_SECRET_KEY from local-infra/langfuse/.env>
```
