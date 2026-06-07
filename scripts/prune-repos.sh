#!/usr/bin/env bash
#
# prune-repos.sh — remove locally-mirrored repositories you are not involved in.
#
# For every cloned repo under <sync-root>/<owner>/<repo>/:
#   - KEEP if you own it       (owner folder == your GitHub login)
#   - KEEP if you authored      >= 1 commit on any branch (by your identities)
#   - otherwise PRUNE:          delete the local clone AND append "owner/repo"
#                               to the ignore file so future syncs skip it.
#
# Repos with uncommitted local changes / stashes are skipped unless --force.
# Aborts if your identity can't be determined (so it can never delete blindly).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

SYNC_ROOT="${PROJECT_ROOT}/GitHub"
IGNORE_FILE="${PROJECT_ROOT}/.syncignore"
DRY_RUN=0
FORCE=0
ME_LOGIN=""
EXTRA_AUTHORS=()
AUTHORS=()

usage() {
  cat <<'EOF'
Usage: prune-repos.sh [OPTIONS]

Remove locally-mirrored repositories you are not involved in. For each cloned
repo under <sync-root>/<owner>/<repo>/:
  - KEEP if you own it (owner folder == your GitHub login)
  - KEEP if you have at least one commit on any branch
  - otherwise DELETE the local clone and add "owner/repo" to the ignore file

Options:
  -h, --help          Show this help
  -n, --dry-run       Show what would be pruned; delete nothing
  --force             Prune even repos with uncommitted local changes
  --me LOGIN          Your GitHub login (default: gh api user)
  --author PATTERN    Extra author pattern counted as "you" (repeatable)
  --sync-root PATH    Mirror root (default: ../GitHub)
  --ignore-file PATH  Ignore file to append to (default: ../.syncignore)

Requires: git (and gh, only to auto-detect your login)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      --me) [[ $# -ge 2 ]] || die "--me requires a login"; ME_LOGIN="$2"; shift 2 ;;
      --author) [[ $# -ge 2 ]] || die "--author requires a pattern"; EXTRA_AUTHORS+=("$2"); shift 2 ;;
      --sync-root) [[ $# -ge 2 ]] || die "--sync-root requires a path"; SYNC_ROOT="$2"; shift 2 ;;
      --ignore-file) [[ $# -ge 2 ]] || die "--ignore-file requires a path"; IGNORE_FILE="$2"; shift 2 ;;
      -*) die "Unknown option: $1 (try --help)" ;;
      *) die "Unexpected argument: $1" ;;
    esac
  done
}

# Build the de-duplicated list of author patterns that count as "you":
# your login + git user.name/email + any --author extras.
detect_authors() {
  local email name
  email="$(git config --get user.email 2>/dev/null || true)"
  name="$(git config --get user.name 2>/dev/null || true)"

  # Duplicates are harmless — git log treats repeated --author as OR.
  AUTHORS=()
  [[ -n "$ME_LOGIN" ]] && AUTHORS+=("$ME_LOGIN")
  [[ -n "$email" ]] && AUTHORS+=("$email")
  [[ -n "$name" ]] && AUTHORS+=("$name")
  if (( ${#EXTRA_AUTHORS[@]} > 0 )); then AUTHORS+=("${EXTRA_AUTHORS[@]}"); fi
}

# True if any of your identities authored at least one commit on any ref.
have_my_commit() {
  local repo="$1" a sha
  local -a args=()
  for a in "${AUTHORS[@]}"; do args+=(--author="$a"); done
  sha="$(git -C "$repo" log --all --regexp-ignore-case "${args[@]}" -1 --format=%H 2>/dev/null || true)"
  [[ -n "$sha" ]]
}

# True if the repo has uncommitted changes or stashed work worth protecting.
is_dirty() {
  local repo="$1"
  [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && return 0
  [[ -n "$(git -C "$repo" stash list 2>/dev/null)" ]] && return 0
  return 1
}

add_to_ignore() {
  local fn="$1"
  touch "$IGNORE_FILE"
  grep -qxF "$fn" "$IGNORE_FILE" 2>/dev/null || printf '%s\n' "$fn" >>"$IGNORE_FILE"
}

main() {
  parse_args "$@"
  require_cmd git

  SYNC_ROOT="$(resolve_sync_root "$SYNC_ROOT")"
  [[ -d "$SYNC_ROOT" ]] || die "Sync root does not exist: $SYNC_ROOT"

  if [[ -z "$ME_LOGIN" ]]; then
    require_cmd gh
    ME_LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  [[ -n "$ME_LOGIN" ]] || die "Could not determine your GitHub login (use --me LOGIN)"

  detect_authors
  [[ ${#AUTHORS[@]} -gt 0 ]] || die "Could not determine your commit identities (use --author)"

  log "Owner login: $ME_LOGIN"
  log "Commit identities: ${AUTHORS[*]}"
  [[ "$DRY_RUN" -eq 1 ]] && log "DRY RUN — nothing will be deleted or ignored"

  local me_login_lc
  me_login_lc="$(printf '%s' "$ME_LOGIN" | tr 'A-Z' 'a-z')"

  local kept=0 pruned=0 skipped=0
  local d owner name full_name owner_lc
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -d "$d/.git" ]] || continue
    owner="$(basename "$(dirname "$d")")"
    [[ "$owner" == "$STATE_DIR_NAME" ]] && continue
    name="$(basename "$d")"
    full_name="${owner}/${name}"

    # Keep: you own it (case-insensitive login match).
    owner_lc="$(printf '%s' "$owner" | tr 'A-Z' 'a-z')"
    if [[ "$owner_lc" == "$me_login_lc" ]]; then
      kept=$((kept + 1))
      continue
    fi
    # Keep: you have a commit in it.
    if have_my_commit "$d"; then
      kept=$((kept + 1))
      continue
    fi
    # Protect dirty repos unless forced.
    if [[ "$FORCE" -ne 1 ]] && is_dirty "$d"; then
      log "SKIP (uncommitted local changes): $full_name"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "WOULD PRUNE: $full_name"
      pruned=$((pruned + 1))
      continue
    fi
    log "PRUNE: $full_name (you are not the owner and have no commits)"
    add_to_ignore "$full_name"
    rm -rf "$d"
    rmdir "$(dirname "$d")" 2>/dev/null || true  # drop owner dir if now empty
    pruned=$((pruned + 1))
  done < <(find "$SYNC_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)

  log "Done. kept=$kept pruned=$pruned skipped=$skipped (ignore file: $IGNORE_FILE)"
  if [[ "$DRY_RUN" -eq 1 && "$pruned" -gt 0 ]]; then
    log "Re-run without --dry-run to delete the $pruned repo(s) above and add them to the ignore file."
  fi
  return 0
}

main "$@"
