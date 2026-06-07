# gh-repo-sync

Bash tooling to mirror every GitHub repository your account can access into a
local `<owner>/<repo>/` tree, and generate optional cloc-based code analytics.

The mirrored repositories live under a gitignored `GitHub/` directory and are
**not** part of this repository — only the scripts are.

## Scripts

| Script | What it does |
|--------|--------------|
| `sync-github-repos.sh` | Clone new repos and fetch all branches for existing ones, grouped by owner. Writes `.sync-state/accessible-repos.json`. |
| `generate-analytics.sh` | Produce cloc analytics markdown per owner and across the whole mirror. |

## Requirements

- [`gh`](https://cli.github.com/) (authenticated: `gh auth login`)
- `git`, `jq`
- `cloc` (only for `generate-analytics.sh`)

## Usage

```bash
# Mirror every accessible repo into ./GitHub/<owner>/<repo>/
./sync-github-repos.sh

# Common options
./sync-github-repos.sh --dry-run           # preview without cloning/fetching
./sync-github-repos.sh -j 8                 # N repos in parallel
./sync-github-repos.sh --skip-archived      # skip archived repos
./sync-github-repos.sh --skip-forks         # skip forks
./sync-github-repos.sh --sync-root PATH     # custom destination root

# Regenerate analytics markdown
./generate-analytics.sh
./generate-analytics.sh --root-only         # skip per-owner files
```

Run either script with `--help` for the full option list.

## Layout

```
GitHub/                 # gitignored — your local mirror, not in this repo
  <owner>/
    <repo>/             # git clone
    analytics.md        # generated per-owner stats
  analytics.md          # generated aggregate stats
```
