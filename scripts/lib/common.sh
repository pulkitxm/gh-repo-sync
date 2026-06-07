#!/usr/bin/env bash
# Shared helpers for GitHub mirror scripts.

set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
DEFAULT_SYNC_ROOT="${PROJECT_ROOT}/GitHub"
STATE_DIR_NAME=".sync-state"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

sync_state_dir() {
  local sync_root="$1"
  printf '%s/%s' "$sync_root" "$STATE_DIR_NAME"
}

resolve_sync_root() {
  local root="${1:-$DEFAULT_SYNC_ROOT}"
  mkdir -p "$root"
  (cd "$root" && pwd)
}

# cloc dirs to skip (large vendored / generated trees)
cloc_exclude_dirs() {
  printf '%s' 'node_modules,.git,dist,build,.next,.nuxt,out,coverage,vendor,target,venv,.venv,__pycache__,.turbo,.cache,Pods,.gradle,bin,obj'
}
