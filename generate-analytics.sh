#!/usr/bin/env bash
#
# Generate analytics markdown using cloc:
#   GitHub/<owner>/analytics.md  — per-owner stats
#   GitHub/analytics.md          — aggregate across all owners
#   README.md                    — root overview with links and inaccessible repos
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

SYNC_ROOT="${SCRIPT_DIR}/GitHub"
GENERATED_AT="$(date -u +"%Y-%m-%d %H:%M UTC")"
SKIP_OWNERS=0

usage() {
  cat <<'EOF'
Usage: generate-analytics.sh [OPTIONS] [SYNC_ROOT]

Generate cloc-based analytics markdown for each owner and the mirror root.

Options:
  --root-only    Skip per-owner files; only GitHub/analytics.md + README.md
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root-only) SKIP_OWNERS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        SYNC_ROOT="$1"
        shift
        ;;
    esac
  done
}

# Run cloc, emit JSON on stdout (empty object if no code)
run_cloc_json() {
  local target="$1"
  local exclude
  exclude="$(cloc_exclude_dirs)"

  if [[ ! -e "$target" ]]; then
    echo '{}'
    return 0
  fi

  local json
  json="$(cloc "$target" \
    --quiet \
    --json \
    --exclude-dir="$exclude" \
    2>/dev/null || true)"

  if [[ -z "$json" || "$json" == "{}" ]]; then
    echo '{}'
    return 0
  fi
  printf '%s' "$json"
}

# Sum language stats from cloc JSON into {lang: {nFiles, blank, comment, code}}
merge_cloc_json() {
  local a="$1" b="$2"
  [[ -z "$a" || "$a" == "null" ]] && a='{}'
  [[ -z "$b" || "$b" == "null" ]] && b='{}'
  # Use stdin (not --argjson) so large cloc payloads are not passed on the command line
  jq -s '
    def entries($o):
      [$o | to_entries[] | select(.key != "header" and .key != "SUM")];
    (entries(.[0]) + entries(.[1]))
    | group_by(.key)
    | map({
        key: .[0].key,
        value: (map(.value) | reduce .[] as $item (
          {nFiles: 0, blank: 0, comment: 0, code: 0};
          {
            nFiles: (.nFiles + ($item.nFiles // 0)),
            blank: (.blank + ($item.blank // 0)),
            comment: (.comment + ($item.comment // 0)),
            code: (.code + ($item.code // 0))
          }
        ))
      })
    | from_entries
  ' <(printf '%s\n' "$a") <(printf '%s\n' "$b")
}

cloc_totals() {
  local json="$1"
  [[ -z "$json" || "$json" == "null" ]] && json='{}'
  jq '
    [to_entries[] | select(.key != "header" and .key != "SUM") | .value]
    | if length == 0 then {nFiles: 0, blank: 0, comment: 0, code: 0}
      else reduce .[] as $v (
        {nFiles: 0, blank: 0, comment: 0, code: 0};
        {
          nFiles: (.nFiles + ($v.nFiles // 0)),
          blank: (.blank + ($v.blank // 0)),
          comment: (.comment + ($v.comment // 0)),
          code: (.code + ($v.code // 0))
        }
      ) end
  ' <<<"$json"
}

top_languages_table() {
  local json="$1" limit="${2:-15}"
  jq -r --argjson limit "$limit" '
    [to_entries[] | select(.key != "header" and .key != "SUM")
     | {lang: .key, code: .value.code, nFiles: .value.nFiles}]
    | sort_by(-.code)
    | .[0:$limit][]
    | "| \(.lang) | \(.nFiles) | \(.code | tonumber | .) |"
  ' <<<"$json" 2>/dev/null || true
}

format_number() {
  printf "%'d" "$1" 2>/dev/null || printf "%d" "$1"
}

list_local_repos() {
  local owner="${1:-}"
  local root="$SYNC_ROOT"
  if [[ -n "$owner" ]]; then
    root="${SYNC_ROOT}/${owner}"
  fi
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 2 -type d -name .git -prune -o \
    -mindepth 2 -maxdepth 2 -type d -print 2>/dev/null | while read -r d; do
    [[ -d "${d}/.git" ]] || continue
    basename "$d"
  done
}

discover_owners() {
  find "$SYNC_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$STATE_DIR_NAME" -exec basename {} \; | sort
}

load_accessible_repos() {
  local state_file
  state_file="$(sync_state_dir "$SYNC_ROOT")/accessible-repos.json"
  if [[ -f "$state_file" ]]; then
    jq -c '.accessible_repos // []' "$state_file"
  else
    echo '[]'
  fi
}

# Authoritative list from GitHub API (for inaccessible / missing detection)
fetch_accessible_from_gh() {
  require_cmd gh
  gh auth status >/dev/null 2>&1 || return 1
  local repos='[]'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    repos="$(jq -c \
      --arg o "$(jq -r '.owner' <<<"$line")" \
      --arg n "$(jq -r '.name' <<<"$line")" \
      --arg f "$(jq -r '.full_name' <<<"$line")" \
      '. + [{owner: $o, name: $n, full_name: $f}]' <<<"$repos")"
  done < <(gh api \
    'user/repos?per_page=100&affiliation=owner,collaborator,organization_member,outside&sort=full_name' \
    --paginate \
    --jq '.[] | {owner: .owner.login, name: .name, full_name: .full_name}')
  printf '%s' "$repos"
}

write_owner_analytics() {
  local owner="$1"
  local owner_dir="${SYNC_ROOT}/${owner}"
  local out="${owner_dir}/analytics.md"

  [[ -d "$owner_dir" ]] || return 0

  log "Analytics: $owner"
  local combined
  combined="$(run_cloc_json "$owner_dir")"
  local -a repo_rows=()
  local repo_count=0

  while IFS= read -r repo_path; do
    [[ -n "$repo_path" ]] || continue
    [[ -d "${repo_path}/.git" ]] || continue
    local name
    name="$(basename "$repo_path")"
    repo_count=$((repo_count + 1))

    local repo_json totals code_lines
    repo_json="$(run_cloc_json "$repo_path")"
    totals="$(cloc_totals "$repo_json")"
    code_lines="$(jq -r '.code' <<<"$totals")"

  local top_lang
    top_lang="$(jq -r '
      [to_entries[] | select(.key != "header" and .key != "SUM")
       | {lang: .key, code: .value.code}] | sort_by(-.code) | .[0].lang // "—"
    ' <<<"$repo_json")"

    repo_rows+=("| ${name} | $(format_number "$code_lines") | ${top_lang} |")
  done < <(find "$owner_dir" -mindepth 1 -maxdepth 1 -type d ! -name "$STATE_DIR_NAME" 2>/dev/null | sort)

  local totals_all
  totals_all="$(cloc_totals "$combined")"
  local total_code total_files
  total_code="$(jq -r '.code' <<<"$totals_all")"
  total_files="$(jq -r '.nFiles' <<<"$totals_all")"

  {
    echo "# ${owner} — GitHub Analytics"
    echo ""
    echo "> Generated: ${GENERATED_AT}"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|------:|"
    echo "| Repositories (local) | ${repo_count} |"
    echo "| Files | $(format_number "$total_files") |"
    echo "| Lines of code | $(format_number "$total_code") |"
    echo "| Blank lines | $(format_number "$(jq -r '.blank' <<<"$totals_all")") |"
    echo "| Comment lines | $(format_number "$(jq -r '.comment' <<<"$totals_all")") |"
    echo ""
    echo "## Languages"
    echo ""
    echo "| Language | Files | Lines of code |"
    echo "|----------|------:|--------------:|"
    top_languages_table "$combined" 25
    echo ""
    echo "## Repositories"
    echo ""
    echo "| Repository | LOC | Top language |"
    echo "|------------|----:|:-------------|"
    if [[ ${#repo_rows[@]} -eq 0 ]]; then
      echo "| _none_ | 0 | — |"
    else
      printf '%s\n' "${repo_rows[@]}"
    fi
    echo ""
  } >"$out"

  # Cache for fast root aggregation
  printf '%s' "$combined" >"${owner_dir}/.cloc-cache.json"
}

find_inaccessible_repos() {
  local accessible_json="$1"
  jq -r '.[].full_name' <<<"$accessible_json" | sort -u >"$(mktemp)"
  local acc_file inaccessible_file
  acc_file="$(mktemp)"
  inaccessible_file="$(mktemp)"
  jq -r '.[].full_name' <<<"$accessible_json" | sort -u >"$acc_file"

  find "$SYNC_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while read -r repo_dir; do
    [[ -d "${repo_dir}/.git" ]] || continue
    local owner name full_name
    owner="$(basename "$(dirname "$repo_dir")")"
    [[ "$owner" == "$STATE_DIR_NAME" ]] && continue
    name="$(basename "$repo_dir")"
    full_name="${owner}/${name}"
    if ! grep -qxF "$full_name" "$acc_file" 2>/dev/null; then
      echo "$full_name|$repo_dir"
    fi
  done >"$inaccessible_file" || true

  rm -f "$acc_file"
  cat "$inaccessible_file"
  rm -f "$inaccessible_file"
}

find_missing_repos() {
  local accessible_json="$1"
  local acc_file local_file
  acc_file="$(mktemp)"
  local_file="$(mktemp)"

  jq -r '.[].full_name' <<<"$accessible_json" | sort -u >"$acc_file"
  find "$SYNC_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while read -r d; do
    [[ -d "${d}/.git" ]] || continue
    echo "$(basename "$(dirname "$d")")/$(basename "$d")"
  done | sort -u >"$local_file"

  comm -23 "$acc_file" "$local_file"
  rm -f "$acc_file" "$local_file"
}

load_owner_cloc_cache() {
  local owner_dir="$1"
  local cache="${owner_dir}/.cloc-cache.json"
  if [[ -f "$cache" ]]; then
    cat "$cache"
  else
    run_cloc_json "$owner_dir"
  fi
}

write_root_analytics() {
  local combined='{}'
  local total_repos=0
  local owner

  log "Analytics: root aggregate"
  for owner in $(discover_owners); do
    local owner_dir="${SYNC_ROOT}/${owner}"
    local owner_json repo_n
    owner_json="$(load_owner_cloc_cache "$owner_dir")"
    combined="$(merge_cloc_json "$combined" "$owner_json")"
    repo_n="$(find "$owner_dir" -mindepth 1 -maxdepth 1 -type d -exec test -d '{}/.git' \; -print 2>/dev/null | wc -l | tr -d ' ')"
    total_repos=$((total_repos + repo_n))
  done

  local totals_all owner_count
  totals_all="$(cloc_totals "$combined")"
  owner_count="$(discover_owners | wc -l | tr -d ' ')"

  {
    echo "# GitHub Mirror — Analytics"
    echo ""
    echo "> Generated: ${GENERATED_AT}"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|------:|"
    echo "| Owners / orgs | ${owner_count} |"
    echo "| Repositories (local) | ${total_repos} |"
    echo "| Files | $(format_number "$(jq -r '.nFiles' <<<"$totals_all")") |"
    echo "| Lines of code | $(format_number "$(jq -r '.code' <<<"$totals_all")") |"
    echo ""
    echo "## Languages (all owners)"
    echo ""
    echo "| Language | Files | Lines of code |"
    echo "|----------|------:|--------------:|"
    top_languages_table "$combined" 30
    echo ""
    echo "## Per-owner reports"
    echo ""
    for owner in $(discover_owners); do
      echo "- [${owner}](${owner}/analytics.md)"
    done
    echo ""
  } >"${SYNC_ROOT}/analytics.md"
}

write_readme() {
  local accessible_json="$1"
  local failures_json="${2:-[]}"

  local accessible_count owner_count local_count
  accessible_count="$(jq 'length' <<<"$accessible_json")"
  owner_count="$(discover_owners | wc -l | tr -d ' ')"
  local_count="$(find "$SYNC_ROOT" -mindepth 3 -maxdepth 3 -type d -name .git 2>/dev/null | wc -l | tr -d ' ')"

  local combined totals_all
  combined='{}'
  for owner in $(discover_owners); do
    local ojson
    ojson="$(load_owner_cloc_cache "${SYNC_ROOT}/${owner}")"
    combined="$(merge_cloc_json "$combined" "$ojson")"
  done
  totals_all="$(cloc_totals "$combined")"

  local inaccessible missing
  inaccessible="$(find_inaccessible_repos "$accessible_json")"
  missing="$(find_missing_repos "$accessible_json")"

  {
    echo "# gh-repo-sync"
    echo ""
    echo "> Last updated: ${GENERATED_AT}"
    echo ""
    echo "Local mirror of every GitHub repository this account can access, grouped by owner."
    echo ""
    echo "## Overview"
    echo ""
    echo "| Metric | Count |"
    echo "|--------|------:|"
    echo "| GitHub owners / orgs (folders) | ${owner_count} |"
    echo "| Repositories on GitHub (last sync) | ${accessible_count} |"
    echo "| Repositories cloned locally | ${local_count} |"
    echo "| Total lines of code (cloc) | $(format_number "$(jq -r '.code' <<<"$totals_all")") |"
    echo ""
    echo "## Top languages"
    echo ""
    echo "| Language | Lines of code |"
    echo "|----------|--------------:|"
    jq -r '
      [to_entries[] | select(.key != "header" and .key != "SUM")
       | {lang: .key, code: .value.code}] | sort_by(-.code) | .[0:10][]
       | "| \(.lang) | \(.code) |"
    ' <<<"$combined"
    echo ""
    echo "## Documentation"
    echo ""
    echo "- [Full analytics](GitHub/analytics.md)"
    for owner in $(discover_owners); do
      echo "- [${owner}](GitHub/${owner}/analytics.md)"
    done
    echo ""
    echo "## Commands"
    echo ""
    echo '```bash'
    echo "make sync       # Clone new repos + fetch all branches"
    echo "make analytics  # Regenerate analytics markdown"
    echo "make refresh    # sync + analytics"
    echo '```'
    echo ""

    if [[ -n "$missing" ]]; then
      echo "## Not cloned locally"
      echo ""
      echo "These repositories are accessible on GitHub but are not present locally (clone failed or not yet synced):"
      echo ""
      while IFS= read -r fn; do
        [[ -n "$fn" ]] || continue
        echo "- \`${fn}\`"
      done <<<"$missing"
      echo ""
    fi

    if [[ "$(jq 'length' <<<"$failures_json")" -gt 0 ]]; then
      echo "## Last sync failures"
      echo ""
      jq -r '.[] | "- `\(.)`"' <<<"$failures_json"
      echo ""
    fi

    if [[ -n "$inaccessible" ]]; then
      echo "## No longer accessible (kept locally)"
      echo ""
      echo "These directories remain on disk but are **not** in your current GitHub access list. They are not deleted automatically."
      echo ""
      while IFS='|' read -r fn path; do
        [[ -n "$fn" ]] || continue
        echo "- \`${fn}\` → \`${path}\`"
      done <<<"$inaccessible"
      echo ""
    fi

    echo "## Layout"
    echo ""
    echo '```'
    echo "GitHub/"
    echo "  <owner>/"
    echo "    <repo>/     # git clone"
    echo "    analytics.md"
    echo "  analytics.md"
    echo '```'
    echo ""
  } >"${SCRIPT_DIR}/README.md"
}

main() {
  parse_args "$@"
  require_cmd jq
  require_cmd cloc
  require_cmd find

  SYNC_ROOT="$(resolve_sync_root "$SYNC_ROOT")"
  [[ -d "$SYNC_ROOT" ]] || die "Sync root does not exist: $SYNC_ROOT (run make sync first)"

  local accessible failures
  if accessible="$(fetch_accessible_from_gh 2>/dev/null)" && [[ "$(jq 'length' <<<"$accessible")" -gt 0 ]]; then
    log "Using live GitHub API list ($(jq 'length' <<<"$accessible") repos)"
  else
    accessible="$(load_accessible_repos)"
    log "Using cached sync state ($(jq 'length' <<<"$accessible") repos)"
  fi
  failures='[]'
  local fail_file
  fail_file="$(sync_state_dir "$SYNC_ROOT")/last-sync-failures.json"
  [[ -f "$fail_file" ]] && failures="$(cat "$fail_file")"

  if [[ "$SKIP_OWNERS" -eq 0 ]]; then
    for owner in $(discover_owners); do
      write_owner_analytics "$owner"
    done
  else
    log "Skipping per-owner analytics (--root-only)"
    # Ensure cloc cache exists for root/README aggregation
    for owner in $(discover_owners); do
      local owner_dir="${SYNC_ROOT}/${owner}"
      [[ -f "${owner_dir}/.cloc-cache.json" ]] && continue
      log "Building cloc cache: $owner"
      run_cloc_json "$owner_dir" >"${owner_dir}/.cloc-cache.json"
    done
  fi

  write_root_analytics
  write_readme "$accessible" "$failures"

  log "Wrote ${SYNC_ROOT}/analytics.md and per-owner analytics.md files"
  log "Wrote ${SCRIPT_DIR}/README.md"
}

main "$@"
