#!/usr/bin/env bash
# Run GitHub Actions CI (.github/workflows/ci.yml) locally using nektos/act.
#
# Usage:
#   bash scripts/run_act.sh               # Run both HyperDX+Grafana and Langfuse CI smoke test jobs
#   bash scripts/run_act.sh hyperdx       # Run only test-hyperdx-stack (HyperDX + Grafana)
#   bash scripts/run_act.sh langfuse      # Run only test-langfuse-stack
#   bash scripts/run_act.sh lint          # Run only lint-commits
#   bash scripts/run_act.sh list          # List all jobs in ci.yml
#   bash scripts/run_act.sh dry-run       # Dry-run ci.yml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW_FILE=".github/workflows/ci.yml"

# Resolve act binary (PATH or ~/.local/bin/act)
if command -v act >/dev/null 2>&1; then
  ACT_BIN="$(command -v act)"
elif [ -x "${HOME}/.local/bin/act" ]; then
  ACT_BIN="${HOME}/.local/bin/act"
else
  echo "ERROR: 'act' binary not found in PATH or ~/.local/bin/act" >&2
  exit 1
fi

TARGET="${1:-all}"
shift || true

run_job() {
  local job_id="$1"
  shift
  echo "=========================================================="
  echo " Running act job: ${job_id}"
  echo "=========================================================="
  "$ACT_BIN" push \
    -j "$job_id" \
    -W "$WORKFLOW_FILE" \
    -P ubuntu-latest=-self-hosted \
    --env LOCAL_INFRA_ROOT="$REPO_ROOT" \
    "$@"
}

case "$TARGET" in
  list|-l|--list)
    "$ACT_BIN" -l -W "$WORKFLOW_FILE" "$@"
    ;;
  dry-run|-n|--dryrun)
    "$ACT_BIN" push -n -W "$WORKFLOW_FILE" -P ubuntu-latest=-self-hosted --env LOCAL_INFRA_ROOT="$REPO_ROOT" "$@"
    ;;
  hyperdx|grafana|test-hyperdx-stack)
    run_job "test-hyperdx-stack" "$@"
    ;;
  langfuse|test-langfuse-stack)
    run_job "test-langfuse-stack" "$@"
    ;;
  lint|lint-commits)
    "$ACT_BIN" push -j "lint-commits" -W "$WORKFLOW_FILE" "$@"
    ;;
  all)
    run_job "test-hyperdx-stack" "$@"
    echo ""
    run_job "test-langfuse-stack" "$@"
    ;;
  *)
    # Allow passing any exact job ID directly
    run_job "$TARGET" "$@"
    ;;
esac
