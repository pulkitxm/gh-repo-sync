#!/usr/bin/env bash
# Fetch and update all branches for a single local git repository.

set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: git-sync-repo.sh <repo-path> [--dry-run]

  - git fetch --all --prune --tags
  - Update local branch refs to match their remote tracking branches
  - Fast-forward merge when on a branch with a clean working tree (best effort)
EOF
}

sync_repo_all_branches() {
  local repo="$1"
  local dry_run="${2:-0}"

  [[ -d "$repo/.git" ]] || die "Not a git repository: $repo"

  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] sync all branches: $repo"
    return 0
  fi

  # Ensure we fetch all heads from every remote
  git -C "$repo" config --local remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null || true
  for remote in $(git -C "$repo" remote); do
    git -C "$repo" fetch "$remote" --prune --tags 2>/dev/null || git -C "$repo" fetch "$remote" --prune || true
  done

  local current_branch
  current_branch="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null | sed 's#refs/heads/##' || true)"
  local had_changes=0
  if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    had_changes=1
  fi

  # Point local branches at remote tips (no checkout required)
  while IFS= read -r remote_ref; do
    [[ -n "$remote_ref" ]] || continue
    local remote="${remote_ref%%/*}"
    local branch="${remote_ref#${remote}/}"
    [[ "$branch" == "HEAD" ]] && continue
    [[ "$branch" == *"->"* ]] && continue

    if git -C "$repo" show-ref --verify --quiet "refs/heads/${branch}"; then
      git -C "$repo" update-ref "refs/heads/${branch}" "refs/remotes/${remote}/${branch}"
    else
      git -C "$repo" branch --track "${branch}" "${remote}/${branch}" 2>/dev/null \
        || git -C "$repo" branch "${branch}" "${remote}/${branch}"
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' "refs/remotes/" 2>/dev/null \
    | grep -E '^[^/]+/.+' | grep -v '/HEAD$' || true)

  # Fast-forward current branch if clean
  if [[ "$had_changes" -eq 0 && -n "$current_branch" ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/${current_branch}"; then
      git -C "$repo" merge --ff-only "origin/${current_branch}" 2>/dev/null \
        || git -C "$repo" reset --hard "origin/${current_branch}" 2>/dev/null || true
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  dry_run=0
  [[ "${2:-}" == "--dry-run" ]] && dry_run=1
  [[ $# -ge 1 ]] || { usage; exit 1; }
  sync_repo_all_branches "$1" "$dry_run"
fi
