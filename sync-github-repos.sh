#!/usr/bin/env bash
#
# Sync all GitHub repositories you have access to into:
#   <sync-root>/<owner-login>/<repo-name>/
#
# - New repos: full clone, then fetch all branches
# - Existing repos: fetch --all and update every branch ref
# - Writes .sync-state/accessible-repos.json for analytics
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/git-sync-repo.sh
source "${SCRIPT_DIR}/scripts/lib/git-sync-repo.sh"

DEFAULT_SYNC_ROOT="${SCRIPT_DIR}/GitHub"

SYNC_ROOT="$DEFAULT_SYNC_ROOT"
DRY_RUN=0
JOBS=4
SHALLOW=0
SKIP_ARCHIVED=0
SKIP_FORKS=0
AFFILIATIONS="owner,collaborator,organization_member,outside"

usage() {
  cat <<'EOF'
Usage: sync-github-repos.sh [OPTIONS] [SYNC_ROOT]

Clone or update every repository your GitHub account can access into:
  SYNC_ROOT/<owner>/<repo>/

Existing clones are always updated (all branches fetched).

Options:
  -h, --help           Show this help
  -n, --dry-run        List actions without cloning/fetching
  -j, --jobs N         Process N repos in parallel (default: 4)
  --shallow            Shallow clone new repos only (--depth 1)
  --skip-archived      Skip archived repositories
  --skip-forks         Skip forked repositories
  --sync-root PATH     Destination root directory

Environment:
  GITHUB_SYNC_ROOT     Default sync root

Requires: gh (authenticated), git, jq
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -j|--jobs)
        [[ $# -ge 2 ]] || die "--jobs requires a number"
        JOBS="$2"
        shift 2
        ;;
      --shallow) SHALLOW=1; shift ;;
      --skip-archived) SKIP_ARCHIVED=1; shift ;;
      --skip-forks) SKIP_FORKS=1; shift ;;
      --sync-root)
        [[ $# -ge 2 ]] || die "--sync-root requires a path"
        SYNC_ROOT="$2"
        shift 2
        ;;
      -*)
        die "Unknown option: $1 (try --help)"
        ;;
      *)
        SYNC_ROOT="$1"
        shift
        ;;
    esac
  done

  if [[ -n "${GITHUB_SYNC_ROOT:-}" && "$SYNC_ROOT" == "$DEFAULT_SYNC_ROOT" ]]; then
    SYNC_ROOT="$GITHUB_SYNC_ROOT"
  fi

  if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    die "--jobs must be a positive integer (got: $JOBS)"
  fi
}

check_gh_auth() {
  gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub. Run: gh auth login"
}

build_gh_jq_query() {
  local conditions=()
  [[ "$SKIP_ARCHIVED" -eq 1 ]] && conditions+=('(.archived | not)')
  [[ "$SKIP_FORKS" -eq 1 ]] && conditions+=('(.fork | not)')

  local select_clause="."
  if [[ ${#conditions[@]} -gt 0 ]]; then
    local expr="${conditions[0]}"
    local part
    for part in "${conditions[@]:1}"; do
      expr+=" and ${part}"
    done
    select_clause="select(${expr})"
  fi

  printf '.[] | %s | {owner: .owner.login, name: .name, full_name: .full_name, archived: .archived, fork: .fork, private: .private}' "$select_clause"
}

list_repos() {
  local jq_query
  jq_query="$(build_gh_jq_query)"
  gh api \
    "user/repos?per_page=100&affiliation=${AFFILIATIONS}&sort=full_name" \
    --paginate \
    --jq "$jq_query"
}

repo_target_dir() {
  printf '%s/%s/%s' "$SYNC_ROOT" "$1" "$2"
}

sync_one() {
  local full_name="$1" target="$2"
  mkdir -p "$(dirname "$target")"

  if [[ -d "$target/.git" ]]; then
    log "Update: $full_name"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      sync_repo_all_branches "$target" 0
    fi
    return 0
  fi

  if [[ -e "$target" ]]; then
    log "FAILED: $full_name — path exists but is not a git repo: $target"
    return 1
  fi

  log "Clone: $full_name -> $target"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if [[ "$SHALLOW" -eq 1 ]]; then
    gh repo clone "$full_name" "$target" -- --depth 1
    sync_repo_all_branches "$target" 0
  else
    gh repo clone "$full_name" "$target"
    sync_repo_all_branches "$target" 0
  fi
}

write_sync_state() {
  local manifest="$1" me="$2"
  local state_dir
  state_dir="$(sync_state_dir "$SYNC_ROOT")"
  mkdir -p "$state_dir"

  local repos_json="[]"
  while IFS=$'\t' read -r full_name target; do
    [[ -n "$full_name" ]] || continue
    local owner name
    owner="${full_name%%/*}"
    name="${full_name#*/}"
    repos_json="$(jq -c \
      --arg fn "$full_name" --arg o "$owner" --arg n "$name" --arg p "$target" \
      '. + [{full_name: $fn, owner: $o, name: $n, path: $p}]' <<<"$repos_json")"
  done <"$manifest"

  jq -n \
    --arg synced_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg account "$me" \
    --argjson repos "$repos_json" \
    '{synced_at: $synced_at, github_account: $account, accessible_repos: $repos}' \
    >"${state_dir}/accessible-repos.json"

  # Failures from this run (if any)
  if [[ -f "${state_dir}/.failures.tmp" ]]; then
    if [[ -s "${state_dir}/.failures.tmp" ]]; then
      jq -R -s 'split("\n") | map(select(length>0))' "${state_dir}/.failures.tmp" \
        >"${state_dir}/last-sync-failures.json"
    else
      echo '[]' >"${state_dir}/last-sync-failures.json"
    fi
    rm -f "${state_dir}/.failures.tmp"
  fi
}

run_sync() {
  local manifest="$1"
  local state_dir failures_file
  state_dir="$(sync_state_dir "$SYNC_ROOT")"
  mkdir -p "$state_dir"
  failures_file="${state_dir}/.failures.tmp"
  : >"$failures_file"

  local total
  total="$(wc -l <"$manifest" | tr -d ' ')"
  log "Sync root: $SYNC_ROOT"
  log "Repositories to process: $total (jobs=$JOBS)"

  _record_failure() {
    local name="$1"
    echo "$name" >>"$failures_file"
  }

  if [[ "$JOBS" -eq 1 ]]; then
    while IFS=$'\t' read -r full_name target; do
      [[ -n "$full_name" ]] || continue
      sync_one "$full_name" "$target" || _record_failure "$full_name"
    done <"$manifest"
  else
    while IFS=$'\t' read -r full_name target; do
      [[ -n "$full_name" ]] || continue
      (
        sync_one "$full_name" "$target" || echo "$full_name" >>"$failures_file"
      ) &
      while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do
        wait -n 2>/dev/null || true
      done
    done <"$manifest"
    wait 2>/dev/null || true
  fi

  local failed=0
  failed="$(wc -l <"$failures_file" | tr -d ' ')"
  if [[ "$failed" -gt 0 ]]; then
    log "Completed with $failed failure(s) — see ${state_dir}/last-sync-failures.json"
    return 1
  fi
  return 0
}

main() {
  parse_args "$@"
  require_cmd gh
  require_cmd git
  require_cmd jq
  check_gh_auth

  local me
  me="$(gh api user --jq .login)"
  log "Authenticated as: $me"

  SYNC_ROOT="$(resolve_sync_root "$SYNC_ROOT")"

  local manifest
  manifest="$(mktemp)"
  trap '[[ -n "${manifest:-}" ]] && rm -f "$manifest"' EXIT

  log "Fetching repository list from GitHub..."
  local count=0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local owner name full_name target
    owner="$(jq -r '.owner' <<<"$line")"
    name="$(jq -r '.name' <<<"$line")"
    full_name="$(jq -r '.full_name' <<<"$line")"
    target="$(repo_target_dir "$owner" "$name")"
    printf '%s\t%s\n' "$full_name" "$target" >>"$manifest"
    count=$((count + 1))
  done < <(list_repos)

  local owner_count
  owner_count="$(cut -f2 "$manifest" | sed "s|${SYNC_ROOT}/||" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')"

  log "Owners (top-level folders): $owner_count"
  log "Total repositories: $count"

  [[ "$count" -eq 0 ]] && { log "No repositories to sync."; exit 0; }

  run_sync "$manifest" || true
  write_sync_state "$manifest" "$me"

  log "Done. Repositories are under: $SYNC_ROOT"
}

main "$@"
