# code-stats

Fast Bun CLI that shows how much code **you** produced across all your
locally-mirrored GitHub repos — last 7 days, by weekday, by language, top days,
or a specific date. Counts your commits across multiple git identities
(names + emails), in parallel, with caching.

## Usage

```bash
bun cli.ts                 # last 7 days + weekday + language
bun cli.ts --whoami        # list every author identity; tune me.json
bun cli.ts --lang ts       # restrict to one language (name or extension)
bun cli.ts --date 2026-06-01   # one day's language breakdown
bun cli.ts --top 10        # your biggest days
bun cli.ts --days 30       # widen the recent window (default 7)
bun cli.ts --net           # net growth (rawAdded - rawDeleted) instead of added+updated
bun cli.ts --json          # machine-readable cube + identities
bun cli.ts --fresh         # delete + rebuild cache
bun cli.ts --root /path/to/GitHub   # override mirror location
```

Flags compose: `bun cli.ts --date 2026-06-05 --lang ts`,
`bun cli.ts --top 10 --lang python`.

## How it counts

- `added` = brand-new lines; `updated` = edited lines (`min(-,+)` per diff hunk);
  deletions are tracked but not shown (use `--net`). Bars show `█ added` then
  `▒ updated`, with the total and a `(+added ~updated)` split.
- **Identity** is decided by `me.json` (name/email substrings + exact emails),
  **not** by folder — so your commits count even in forks and work orgs, and
  upstream authors in those repos are excluded. Run `--whoami` to discover and
  add identities (old usernames/emails you've used).
- **All branches**: uses `git log --all`, so unmerged and remote-only branch work
  counts. Git emits each commit once per repo; identical SHAs across cloned repos
  (a repo + its fork) are deduped globally. Rebased/cherry-picked copies have
  different SHAs and may count more than once.
- **Generated noise excluded**: lock files, `*.min.*`, `node_modules/`, `dist/`,
  `build/`, `vendor/`, `.next/`, etc. — both at the git level (pathspecs, for
  speed) and during parsing.

## Performance

- Repos are processed in parallel and **streamed** — output is parsed line by
  line, so memory stays bounded even on repos with multi-GB diffs.
- Per-repo results are cached in `cache.json`, keyed by a fingerprint of **all
  ref tips** (not just HEAD, since we walk every branch). Re-runs only touch
  repos whose refs changed; `--fresh` rebuilds everything.

## me.json

Auto-created on first run (gitignored). Add any of YOUR names/emails:

```json
{
  "substrings": ["octocat"],
  "emails": ["you@example.com"]
}
```

- `substrings` match (case-insensitive) anywhere in `Name <email>` — a login
  like `"octocat"` also covers your display name and GitHub noreply
  `…+octocat@users.noreply.github.com`.
- `emails` are exact matches — use for old emails that don't contain your name.

After editing, run `bun cli.ts --fresh` to recount.

## Tests

```bash
bun test
```
