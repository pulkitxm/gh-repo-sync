#!/usr/bin/env bash
#
# prune-repos.sh — remove locally-mirrored repositories you are not involved in.
#
# For every cloned repo under <sync-root>/<owner>/<repo>/:
#   - KEEP if you authored >= 1 commit on any branch (by your identities)
#   - KEEP if it's your own ORIGINAL repo (you own it and it isn't a fork)
#   - otherwise PRUNE (includes forks you own but never committed to):
#       delete the local clone AND append "owner/repo" to the ignore file
#       so future syncs skip it.
#
# Repos with untracked files or stashes are skipped unless --force.
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
FORKS_FILE=""

usage() {
  cat <<'EOF'
Usage: prune-repos.sh [OPTIONS]

Remove locally-mirrored repositories you are not involved in. For each cloned
repo under <sync-root>/<owner>/<repo>/:
  - KEEP if you have at least one commit on any branch
  - KEEP if it's your own original repo (you own it and it is not a fork)
  - otherwise DELETE the local clone and add "owner/repo" to the ignore file
    (this includes forks you own but have no commits in)

Options:
  -h, --help          Show this help
  -n, --dry-run       Show what would be pruned; delete nothing
  --force             Prune even repos with untracked files or stashes
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

# Build the list of author patterns that count as "you": your GitHub login and
# commit email (plus any --author extras). The git display name is excluded on
# purpose — too generic to match reliably.
detect_authors() {
  local email
  email="$(git config --get user.email 2>/dev/null || true)"

  # Match ONLY your GitHub login and commit email — never the git display name.
  # A bare display name (e.g. a first name) is too generic and would match
  # unrelated contributors with the same name in large forked repos, wrongly
  # keeping those forks. Duplicates are harmless (git log ORs --author flags).
  AUTHORS=()
  [[ -n "$ME_LOGIN" ]] && AUTHORS+=("$ME_LOGIN")
  [[ -n "$email" ]] && AUTHORS+=("$email")
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

# True if the repo holds work that deleting the clone would IRREPLACEABLY lose:
# stashes or untracked (non-ignored) files. Modified/deleted tracked files and
# "unpushed" commits are deliberately ignored — their content is in git/on the
# remote, and the sync leaves stale worktrees + extra local branches that look
# like huge diffs but are not real work. Only stashes and untracked files are
# things the sync never fabricates.
is_dirty() {
  local repo="$1"
  [[ -n "$(git -C "$repo" stash list 2>/dev/null)" ]] && return 0
  [[ -n "$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]] && return 0
  return 1
}

add_to_ignore() {
  local fn="$1"
  touch "$IGNORE_FILE"
  grep -qxF "$fn" "$IGNORE_FILE" 2>/dev/null || printf '%s\n' "$fn" >>"$IGNORE_FILE"
}

# Fetch the set of forked repositories (one full_name per line) from GitHub.
# On any failure the set is left empty, so owned repos are kept (safe default).
fetch_forks() {
  FORKS_FILE="$(mktemp)"
  if ! command -v gh >/dev/null 2>&1; then
    log "gh not found — cannot detect forks; your owned repos will all be kept"
    return 0
  fi
  if ! gh api \
      "user/repos?per_page=100&affiliation=owner,collaborator,organization_member,outside&sort=full_name" \
      --paginate --jq '.[] | select(.fork) | .full_name' \
      >"$FORKS_FILE" 2>/dev/null; then
    log "Could not fetch fork list from GitHub; your owned repos will all be kept"
    : >"$FORKS_FILE"
  fi
}

# True if full_name is a fork (per the GitHub API list).
is_fork() {
  [[ -n "$FORKS_FILE" && -s "$FORKS_FILE" ]] || return 1
  grep -qxF "$1" "$FORKS_FILE"
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

  trap '[[ -n "${FORKS_FILE:-}" ]] && rm -f "$FORKS_FILE"' EXIT
  fetch_forks
  if [[ -s "$FORKS_FILE" ]]; then
    log "Forks on GitHub: $(wc -l <"$FORKS_FILE" | tr -d ' ') (owned forks need a commit to be kept)"
  fi

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

    owner_lc="$(printf '%s' "$owner" | tr 'A-Z' 'a-z')"

    # Keep: you have a commit in it (any branch).
    if have_my_commit "$d"; then
      kept=$((kept + 1))
      continue
    fi
    # Keep: your own ORIGINAL repo (you own it and it is not a fork).
    # Forks you own but never committed to fall through to the prune path.
    if [[ "$owner_lc" == "$me_login_lc" ]] && ! is_fork "$full_name"; then
      kept=$((kept + 1))
      continue
    fi
    # Protect dirty repos unless forced.
    if [[ "$FORCE" -ne 1 ]] && is_dirty "$d"; then
      log "SKIP (has stashes or untracked files): $full_name"
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
