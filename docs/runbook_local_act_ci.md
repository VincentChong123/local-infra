# Runbook: Local CI Execution with `nektos/act` & GitHub Ruleset Compliance

This runbook guides developers and operators on running [.github/workflows/ci.yml](file:///.github/workflows/ci.yml) locally using **`nektos/act`**, maintaining our minimal custom runner image, and ensuring changes comply with GitHub repository protection rulesets defined in [.github/rulesets/](file:///.github/rulesets/).

---

## 1. Overview & Architecture

To replace reliance on `github.com` cloud runner minutes and catch issues before code leaves developer workstations, `local-infra` supports executing the full GitHub Actions workflow locally.

```
                    git push
                       │
                       ▼
       ┌───────────────────────────────┐
       │   .git/hooks/pre-push (prek)  │
       └───────────────┬───────────────┘
                       │ triggers
                       ▼
       ┌───────────────────────────────┐
       │       act workflow_dispatch   │
       │  (.github/workflows/ci.yml)   │
       └───────────────┬───────────────┘
                       │ mounts /var/run/docker.sock
                       ▼
    ┌─────────────────────────────────────┐
    │     local-infra-runner:latest       │
    │  - Node.js 20 & Commitlint CLI      │
    │  - Git & Bash POSIX utilities       │
    │  - Docker CLI & Compose v2 Plugin   │
    └──────────────────┬──────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
┌──────────────────┐        ┌──────────────────┐
│   lint-commits   │        │  detect-changes  │
└──────────────────┘        └─────────┬────────┘
                                      │ if changed
                        ┌─────────────┴─────────────┐
                        ▼                           ▼
              ┌──────────────────┐        ┌──────────────────┐
              │ test-langfuse    │        │  test-hyperdx    │
              └──────────────────┘        └──────────────────┘
```

### Key Components

| Component | Path | Description |
|---|---|---|
| **Workflow Definition** | [.github/workflows/ci.yml](file:///.github/workflows/ci.yml) | Multi-stage pipeline: commit message linting, change detection, and service smoke testing. |
| **Runner Dockerfile** | [.github/act/Dockerfile](file:///.github/act/Dockerfile) | Zero-bloat custom runner image based on Ubuntu 24.04 (~200MB vs ~2GB+ third-party images). |
| **Act Configuration** | [.actrc](file:///.actrc) | Maps `ubuntu-latest` to `local-infra-runner:latest`, mounts `/var/run/docker.sock`, and sets `--pull=false`. |
| **Pre-Push Hook** | [.pre-commit-config.yaml](file:///.pre-commit-config.yaml) | Prek/pre-commit stage ensuring CI runs automatically before `git push`. |
| **Repository Rulesets** | [.github/rulesets/](file:///.github/rulesets/) | JSON export of GitHub branch rules and required status checks. |

---

## 2. Prerequisites

Ensure the following tools are installed on your host system:
1. **Docker Engine**: running and accessible via `/var/run/docker.sock`.
   ```bash
   docker ps
   ```
2. **`act` CLI**: installed at `~/.local/bin/act` or in your system `$PATH`.
   ```bash
   act --version
   ```
3. **`prek`** (or `pre-commit`): Python/uv-based git hook manager.
   ```bash
   prek --version
   ```

---

## 3. Building / Updating the Local Runner Image

The repository uses an in-house minimal runner image instead of third-party community images.

To build or rebuild the image:

```bash
docker build -t local-infra-runner:latest -f .github/act/Dockerfile .
```

Verify that the image is built and available:

```bash
docker images local-infra-runner:latest
```

The runner image contains:
- `ubuntu:24.04` base
- `bash`, `git`, `curl`, `ca-certificates`, `openssl`, `tar`, `gzip`
- `nodejs`, `npm`, `docker.io`, `docker-compose-v2`
- Globally pre-installed `@commitlint/cli` and `@commitlint/config-conventional`

---

## 4. Manual Execution with `act`

### 4.1 Fast Dry-Run (Syntax & Step Verification)
Validates workflow syntax, job dependencies, and steps without running containers:

```bash
act workflow_dispatch -W .github/workflows/ci.yml -n
```

### 4.2 Run the Entire CI Pipeline Locally
Executes all jobs sequentially according to dependency requirements:

```bash
act workflow_dispatch -W .github/workflows/ci.yml
```

### 4.3 Run Specific Jobs
You can isolate individual jobs using the `-j` flag:

- **Lint Commit Messages only:**
  ```bash
  act workflow_dispatch -W .github/workflows/ci.yml -j lint-commits
  ```

- **Detect Changed Services only:**
  ```bash
  act workflow_dispatch -W .github/workflows/ci.yml -j detect-changes
  ```

- **Langfuse Stack Smoke Test:**
  ```bash
  act workflow_dispatch -W .github/workflows/ci.yml -j test-langfuse-stack
  ```

- **HyperDX Stack Smoke Test:**
  ```bash
  act workflow_dispatch -W .github/workflows/ci.yml -j test-hyperdx-stack
  ```

---

## 5. Automated Git Hook (`git push`)

The repository is configured to automatically trigger `act` before code is pushed to remote.

### 5.1 Pre-Push Configuration
In [.pre-commit-config.yaml](file:///.pre-commit-config.yaml):
```yaml
  - repo: local
    hooks:
      - id: act-local-ci
        name: Run GitHub CI workflow locally via nektos/act
        entry: act workflow_dispatch -W .github/workflows/ci.yml
        language: system
        pass_filenames: false
        always_run: true
        stages: [pre-push]
```

### 5.2 Installing the Hook
If working on a fresh clone, register the pre-push hook with:
```bash
prek install --hook-type pre-push
```

### 5.3 Testing the Hook Manually
To test the pre-push hook without issuing a `git push`:
```bash
prek run act-local-ci --hook-stage pre-push
```

---

## 6. GitHub Ruleset Compliance & Status Checks

The `.github/rulesets/` directory documents branch protection rules configured on GitHub:

### 6.1 `branch-rule-name-pr-01.json`
Protects `~DEFAULT_BRANCH` (`main`):
- **Pull Request Requirements**:
  - `required_approving_review_count`: 1 approval required before merge.
  - `dismiss_stale_reviews_on_push`: true.
  - `required_review_thread_resolution`: all PR comments must be resolved.
- **Required Status Checks**:
  - `Lint Commit Messages` (matches `ci.yml` job `lint-commits`).
  - `Validate Cross-Service Error Codes`.
  - `AI Service Pytest (Python / uv)`.
- **Branch Protections**:
  - `deletion`: blocks deleting the target branch.
  - `non_fast_forward`: blocks force-pushing (`git push --force`).

### 6.2 `ruleset-name-01-PR.json`
Enforces standard PR merge flow on `refs/heads/main`:
- Requires Pull Request with 1 approval.
- Enforces linear git history (`non_fast_forward`).

### 6.3 Local Pre-Flight Checklist
Before pushing code or opening a PR against `main`:
1. **Commit Message Format**: Follow Conventional Commits (`feat: ...`, `fix: ...`, `chore: ...`).
   Verify with:
   ```bash
   act workflow_dispatch -W .github/workflows/ci.yml -j lint-commits
   ```
2. **Service Stack Tests**: If touching `langfuse/` or `hyperdx/`, ensure smoke tests pass locally:
   ```bash
   act workflow_dispatch -W .github/workflows/ci.yml -j test-langfuse-stack
   ```
3. **Execute Pre-Push Validation**:
   ```bash
   git push origin <your-branch>
   ```
   The pre-push hook runs the local CI pipeline and aborts the push if any checks fail.

---

## 7. Troubleshooting & FAQs

### Q: `Error response from daemon: pull access denied for local-infra-runner`
**Fix**: `act` defaults to `--pull=true` (`forcePull=true`), which attempts to fetch the image from Docker Hub registry. Set `--pull=false` in [.actrc](file:///.actrc) so `act` uses the local daemon cache without contacting Docker Hub:
```ini
--pull=false
```

### Q: `act` fails with `Cannot connect to the Docker daemon`
**Fix**: Ensure your Docker daemon is running and [.actrc](file:///.actrc) contains `--container-daemon-socket=/var/run/docker.sock`. Also verify your user is in the `docker` group (`groups $USER`).

### Q: `prek` fails with unstaged file warnings
**Fix**: Prek automatically stashes unstaged modifications before executing pre-push hooks. Stage all relevant modifications (`git add <files>`) before pushing.

### Q: Leftover containers after an interrupted test run
If an `act` run is killed abruptly (Ctrl+C), clean up any lingering service containers:
```bash
docker compose -f langfuse/docker-compose.yaml down -v
docker compose -f hyperdx/docker-compose.yaml down -v
```
