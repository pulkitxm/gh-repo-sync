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

# Default concurrency: scale to the machine. Repo sync is network-latency
# bound, so we want roughly one job per core. Capped to a sane band.
default_jobs() {
  local cores
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null \
    || sysctl -n hw.ncpu 2>/dev/null \
    || echo 4)"
  [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )) || cores=4
  (( cores < 4 )) && cores=4
  (( cores > 16 )) && cores=16
  printf '%s' "$cores"
}

SYNC_ROOT="$DEFAULT_SYNC_ROOT"
DRY_RUN=0
JOBS="$(default_jobs)"
SHALLOW=0

# Stop cleanly on Ctrl+C / TERM. Background jobs in a non-interactive shell
# ignore SIGINT (POSIX), so a bare Ctrl+C leaves in-flight git/gh workers
# running and the dispatch loop spawning more. We broadcast SIGTERM (which is
# NOT auto-ignored) to our whole process group to tear everything down.
handle_interrupt() {
  trap '' INT TERM   # ignore repeats in this shell while we shut down
  log "Interrupted — terminating in-flight git/gh jobs..."
  kill -TERM -$$ 2>/dev/null \
    || kill -TERM $(jobs -p) 2>/dev/null \
    || true
  wait 2>/dev/null || true
  exit 130
}
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
  -j, --jobs N         Process N repos in parallel (default: CPU cores, capped 4-16)
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

  # Emit owner<TAB>name<TAB>full_name. GitHub owner/repo names never contain
  # tabs or spaces, so @tsv is a safe, jq-free-to-parse line format.
  printf '.[] | %s | [.owner.login, .name, .full_name] | @tsv' "$select_clause"
}

list_repos() {
  local jq_query
  jq_query="$(build_gh_jq_query)"
  gh api \
    "user/repos?per_page=100&affiliation=${AFFILIATIONS}&sort=full_name" \
    --paginate \
    --jq "$jq_query"
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

  # Build the whole accessible-repos array in one streaming jq pass over the
  # manifest (TSV: full_name<TAB>target). Avoids the previous O(n^2) rebuild
  # that re-serialized a growing array once per repo.
  jq -R -n \
    --arg synced_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg account "$me" \
    '{synced_at: $synced_at,
      github_account: $account,
      accessible_repos: [inputs
        | split("\t")
        | select(length >= 2 and (.[0] | length > 0))
        | {full_name: .[0],
           owner: (.[0] | split("/")[0]),
           name: (.[0] | sub("^[^/]*/"; "")),
           path: .[1]}]}' \
    "$manifest" >"${state_dir}/accessible-repos.json"

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
  trap handle_interrupt INT TERM

  log "Fetching repository list from GitHub..."
  local count=0

  # Build the manifest (full_name<TAB>target) in a single awk pass over the
  # TSV from GitHub — no per-repo jq subprocess.
  list_repos \
    | awk -F'\t' -v root="$SYNC_ROOT" 'NF { printf "%s\t%s/%s/%s\n", $3, root, $1, $2 }' \
    >"$manifest"
  count="$(wc -l <"$manifest" | tr -d ' ')"

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
