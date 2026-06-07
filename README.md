# gh-repo-sync

Local mirror of every GitHub repository your account can access, into
`GitHub/<owner>/<repo>/` — plus fork pruning, cloc analytics, and a Bun CLI for
your code stats. Only the tooling is tracked; the mirror lives under a
gitignored `GitHub/`.

> ⚠️ **Vibe-coded project — use at your own risk.** Built fast with AI and only
> lightly reviewed. It **deletes** local clones (prune) and **overwrites** local
> state on sync. Read what a command does and keep `--dry-run` handy before
> pointing it at anything you care about.

## Tools

| Command | What it does |
|---------|--------------|
| `scripts/sync-github-repos.sh` | Clone/fetch every accessible repo, grouped by owner. Auto-prunes at the end. |
| `scripts/prune-repos.sh` | Delete forks + repos you're not involved in, and add them to `.syncignore`. |
| `scripts/generate-analytics.sh` | cloc analytics per owner + aggregate + a gitignored `OVERVIEW.md`. |
| `code-stats/` (Bun CLI) | How much code **you** wrote across the mirror — by day, weekday, language. |

## Usage

```bash
gh auth login                       # one-time
./scripts/sync-github-repos.sh      # mirror everything (auto-prunes)
./scripts/sync-github-repos.sh -n   # dry run
./scripts/prune-repos.sh --dry-run  # preview what prune would delete
./scripts/generate-analytics.sh     # regenerate analytics + OVERVIEW.md
cd code-stats && bun cli.ts         # your code stats (--whoami to set identity)
```

Drop a `.syncignore` in the project root (one glob per line, e.g. `owner/repo`
or `owner/*`) to skip repos — see [`.syncignore.example`](.syncignore.example).
Run any script with `--help`.

**Requires:** `gh`, `git`, `jq` (+ `cloc` for analytics, `bun` for code-stats).

## Layout

```
scripts/      # sync / prune / analytics
code-stats/   # Bun code-stats CLI (your me.json is gitignored)
GitHub/       # gitignored — the local mirror itself
```
