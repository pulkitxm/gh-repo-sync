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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/git-sync-repo.sh
source "${SCRIPT_DIR}/git-sync-repo.sh"

DEFAULT_SYNC_ROOT="${PROJECT_ROOT}/GitHub"

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
PRUNE=1

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

# Repos matching a glob in this file are skipped entirely (never cloned or
# updated). One "owner/repo" glob per line; '#' comments and blanks ignored.
DEFAULT_IGNORE_FILE="${PROJECT_ROOT}/.syncignore"
IGNORE_FILE="$DEFAULT_IGNORE_FILE"

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
  --no-prune           Do not run prune-repos.sh after syncing
  --sync-root PATH     Destination root directory
  --ignore-file PATH   Skip repos matching glob patterns in PATH
                       (default: .syncignore beside this script, if present)

Ignore file (.syncignore):
  One glob per line, matched against "owner/repo"; '#' starts a comment.
  Examples:  octocat/Hello-World    myorg/*    */secret-*

Environment:
  GITHUB_SYNC_ROOT     Default sync root
  GITHUB_SYNC_IGNORE   Default ignore-file path

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
      --no-prune) PRUNE=0; shift ;;
      --sync-root)
        [[ $# -ge 2 ]] || die "--sync-root requires a path"
        SYNC_ROOT="$2"
        shift 2
        ;;
      --ignore-file)
        [[ $# -ge 2 ]] || die "--ignore-file requires a path"
        IGNORE_FILE="$2"
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

  if [[ -n "${GITHUB_SYNC_IGNORE:-}" && "$IGNORE_FILE" == "$DEFAULT_IGNORE_FILE" ]]; then
    IGNORE_FILE="$GITHUB_SYNC_IGNORE"
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

# Read skip patterns from the ignore file: one "owner/repo" glob per line,
# with '#' comments and blank lines stripped. Empty output if no file.
load_ignore_patterns() {
  [[ -f "$IGNORE_FILE" ]] || return 0
  sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$IGNORE_FILE" \
    | grep -v '^[[:space:]]*$' || true
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
      # Throttle to $JOBS concurrent. bash 3.2 (macOS default) has no
      # `wait -n`, so poll the running-job count instead.
      while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do
        sleep 0.2
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

  local ignore_patterns
  ignore_patterns="$(load_ignore_patterns)"
  if [[ -n "$ignore_patterns" ]]; then
    log "Ignore file: $IGNORE_FILE ($(printf '%s\n' "$ignore_patterns" | grep -c . || true) pattern(s))"
  fi

  # Build the manifest (full_name<TAB>target) in a single awk pass over the TSV
  # from GitHub — no per-repo jq subprocess. Repos matching a .syncignore glob
  # are dropped here, so they are never cloned or updated.
  local skipfile
  skipfile="$(mktemp)"
  list_repos \
    | IGNORE_PATTERNS="$ignore_patterns" awk -F'\t' -v root="$SYNC_ROOT" -v skipfile="$skipfile" '
        function glob2re(p,   re, i, c) {
          re = "^"
          for (i = 1; i <= length(p); i++) {
            c = substr(p, i, 1)
            if (c == "*") re = re ".*"
            else if (c == "?") re = re "."
            else if (c ~ /[A-Za-z0-9_\/-]/) re = re c
            else re = re "\\" c
          }
          return re "$"
        }
        BEGIN {
          n = split(ENVIRON["IGNORE_PATTERNS"], raw, "\n")
          for (i = 1; i <= n; i++) if (raw[i] != "") pat[++npat] = glob2re(raw[i])
        }
        NF {
          for (i = 1; i <= npat; i++) if ($3 ~ pat[i]) { skipped++; next }
          printf "%s\t%s/%s/%s\n", $3, root, $1, $2
        }
        END { print (skipped + 0) > skipfile }
      ' \
    >"$manifest"

  local ignored=0
  ignored="$(cat "$skipfile" 2>/dev/null || echo 0)"
  rm -f "$skipfile"
  count="$(wc -l <"$manifest" | tr -d ' ')"
  if [[ "${ignored:-0}" -gt 0 ]]; then
    log "Skipped $ignored repo(s) via ignore file"
  fi

  local owner_count
  owner_count="$(cut -f2 "$manifest" | sed "s|${SYNC_ROOT}/||" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')"

  log "Owners (top-level folders): $owner_count"
  log "Total repositories: $count"

  [[ "$count" -eq 0 ]] && { log "No repositories to sync."; exit 0; }

  run_sync "$manifest" || true
  write_sync_state "$manifest" "$me"

  if [[ "$PRUNE" -eq 1 ]]; then
    local prune_sh="${SCRIPT_DIR}/prune-repos.sh"
    if [[ -x "$prune_sh" ]]; then
      log "Pruning repos you don't own and have no commits in..."
      local prune_args=(--sync-root "$SYNC_ROOT" --ignore-file "$IGNORE_FILE" --me "$me")
      [[ "$DRY_RUN" -eq 1 ]] && prune_args+=(--dry-run)
      "$prune_sh" "${prune_args[@]}" || log "Prune step reported an error (continuing)."
    else
      log "Prune script not found or not executable: $prune_sh (skipping)"
    fi
  fi

  log "Done. Repositories are under: $SYNC_ROOT"
}

main "$@"
