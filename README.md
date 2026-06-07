# gh-repo-sync

Bash tooling to mirror every GitHub repository your account can access into a
local `<owner>/<repo>/` tree, and generate optional cloc-based code analytics.

The mirrored repositories live under a gitignored `GitHub/` directory and are
**not** part of this repository — only the scripts are.

## Scripts

| Script | What it does |
|--------|--------------|
| `scripts/sync-github-repos.sh` | Clone new repos and fetch all branches for existing ones, grouped by owner. Writes `GitHub/.sync-state/accessible-repos.json`. |
| `scripts/generate-analytics.sh` | Produce cloc analytics per owner, an aggregate, and a local `OVERVIEW.md` (gitignored). |

## Requirements

- [`gh`](https://cli.github.com/) (authenticated: `gh auth login`)
- `git`, `jq`
- `cloc` (only for analytics)

## Usage

```bash
# Mirror every accessible repo into ./GitHub/<owner>/<repo>/
./scripts/sync-github-repos.sh

# Common options
./scripts/sync-github-repos.sh --dry-run         # preview without cloning/fetching
./scripts/sync-github-repos.sh -j 8              # N repos in parallel (default: CPU cores)
./scripts/sync-github-repos.sh --skip-archived   # skip archived repos
./scripts/sync-github-repos.sh --skip-forks      # skip forks
./scripts/sync-github-repos.sh --sync-root PATH  # custom destination root

# Regenerate analytics (writes GitHub/**/analytics.md and ./OVERVIEW.md)
./scripts/generate-analytics.sh
```

Run either script with `--help` for the full option list.

## Skipping repos (`.syncignore`)

Create a `.syncignore` file in the project root to skip specific repositories —
one glob per line, matched against `owner/repo` (`#` starts a comment):

```
octocat/Hello-World     # one specific repo
myorg/*                 # a whole owner/org
*/secret-*              # any repo whose name starts with "secret-"
```

Matched repos are never cloned or updated; existing local clones are left
untouched. See [`.syncignore.example`](.syncignore.example). Your real
`.syncignore` is gitignored, so private repo names stay local.

## Layout

```
scripts/                # the tooling (tracked)
GitHub/                 # gitignored — your local mirror, not in this repo
  <owner>/
    <repo>/             # git clone
    analytics.md        # generated per-owner stats
  analytics.md          # generated aggregate stats
OVERVIEW.md             # gitignored — generated local overview (contains data)
```
