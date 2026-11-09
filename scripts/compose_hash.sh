#!/usr/bin/env bash
# Shared Docker Compose configuration & .env hash-checking utility.
# Used by grafana, hyperdx, and langfuse startup scripts to decide whether
# `docker compose up -d` needs `--force-recreate`.

# Compute a single combined SHA-256 digest over all compose/env/config files
# located in the provided directories or file paths.
compute_stack_hash() {
  local files=()
  local target

  for target in "$@"; do
    if [ -f "$target" ]; then
      files+=("$target")
    elif [ -d "$target" ]; then
      while IFS= read -r -d '' f; do
        files+=("$f")
      done < <(
        find "$target" -maxdepth 3 \
          \( -name "docker-compose*.yml" \
          -o -name "docker-compose*.yaml" \
          -o -name "*.compose.yml" \
          -o -name "*.compose.yaml" \
          -o -name ".env" \
          -o -name "Dockerfile*" \
          -o -path "*/provisioning/*" \) \
          -type f -print0 | sort -z
      )
    fi
  done

  if [ "${#files[@]}" -eq 0 ]; then
    echo "none"
    return 0
  fi

  # Hash file contents and coalesce into a single deterministic digest
  sha256sum "${files[@]}" | sha256sum | awk '{print $1}'
}

# Usage:
#   compose_up_smart <service_dir> [additional_watch_dirs_or_files...] -- [docker_compose_up_args...]
#
# Checks whether the SHA-256 digest of the stack's compose/.env/provisioning files
# changed since the last run (stored in <service_dir>/.compose.sha256).
# - If changed: runs `docker compose up -d --force-recreate` and updates `.compose.sha256`.
# - If unchanged: runs `docker compose up -d` without `--force-recreate`.
compose_up_smart() {
  local service_dir="$1"
  shift

  local watch_paths=("$service_dir")
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--" ]; then
      shift
      break
    fi
    watch_paths+=("$1")
    shift
  done

  local state_file="$service_dir/.compose.sha256"
  local current_hash
  current_hash="$(compute_stack_hash "${watch_paths[@]}")"

  local previous_hash=""
  if [ -f "$state_file" ]; then
    previous_hash="$(cat "$state_file" 2>/dev/null || true)"
  fi

  if [ -z "$previous_hash" ]; then
    echo "  [hash-check] No previous state found (${current_hash:0:12}...). Running initial 'docker compose up -d'..."
    (cd "$service_dir" && docker compose up -d "$@")
  elif [ "$current_hash" != "$previous_hash" ]; then
    echo "  [hash-check] Config/.env change detected (${previous_hash:0:12}... -> ${current_hash:0:12}...). Running with '--force-recreate'..."
    (cd "$service_dir" && docker compose up -d --force-recreate "$@")
  else
    echo "  [hash-check] Config/.env unchanged (${current_hash:0:12}...). Skipping '--force-recreate'..."
    (cd "$service_dir" && docker compose up -d "$@")
  fi

  echo "$current_hash" > "$state_file"
}
