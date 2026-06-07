import { parseArgs } from "node:util";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, rmSync } from "node:fs";
import { loadMe, makeMatcher, authorPatterns } from "./identity";
import { discoverRepos, refsFingerprint, extractRepo, listAuthors } from "./git";
import { loadCache, saveCache, freshCommits, emptyCache } from "./cache";
import {
  mergeToCube, byWeekday, byLanguage, lastNDays, topDays, dayBreakdown, metricValue,
} from "./aggregate";
import { renderBars, fmt, type BarRow } from "./render";
import { classify } from "./lang";
import type { CacheFile, LangCounts, Metric, MeConfig } from "./types";

const GREEN = "\x1b[32m";
const CYAN = "\x1b[36m";

async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const idx = i++;
      out[idx] = await fn(items[idx]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) || 1 }, worker));
  return out;
}

function todayStr(): string {
  return new Date().toISOString().slice(0, 10);
}

function authoredRow(label: string, c: LangCounts, color: boolean): BarRow {
  return {
    label,
    segments: [
      { value: c.added, char: "█", ansi: color ? GREEN : "" },
      { value: c.updated, char: "▒", ansi: color ? CYAN : "" },
    ],
    note: `(+${fmt(c.added)} ~${fmt(c.updated)})`,
  };
}

function netRow(label: string, c: LangCounts, color: boolean): BarRow {
  return { label, segments: [{ value: Math.max(metricValue(c, "net"), 0), char: "█", ansi: color ? GREEN : "" }], note: "" };
}

function rowFor(label: string, c: LangCounts, metric: Metric, color: boolean): BarRow {
  return metric === "net" ? netRow(label, c, color) : authoredRow(label, c, color);
}

export async function runCli(argv: string[], workdir?: string): Promise<string> {
  const dir = workdir ?? dirname(fileURLToPath(import.meta.url));
  const { values } = parseArgs({
    args: argv,
    options: {
      fresh: { type: "boolean", default: false },
      whoami: { type: "boolean", default: false },
      json: { type: "boolean", default: false },
      net: { type: "boolean", default: false },
      date: { type: "string" },
      lang: { type: "string" },
      top: { type: "string" },
      days: { type: "string", default: "7" },
      root: { type: "string" },
    },
    allowPositionals: false,
  });

  const me = await loadMe(dir);
  const root = values.root ?? join(dir, "..", "GitHub");
  const repos = await discoverRepos(root);
  const isMe = makeMatcher(me);

  // --whoami: scan all authors, rank, flag matches.
  if (values.whoami) {
    const counts = new Map<string, number>();
    await mapLimit(repos, cpuLimit(), async (repo) => {
      const m = await listAuthors(repo);
      for (const [k, v] of m) counts.set(k, (counts.get(k) ?? 0) + v);
    });
    return renderWhoami(counts, isMe);
  }

  // Extract per repo, using cache keyed by refs fingerprint.
  const cachePath = join(dir, "cache.json");
  if (values.fresh && existsSync(cachePath)) rmSync(cachePath);
  const cache: CacheFile = values.fresh ? emptyCache() : await loadCache(dir);
  const pats = authorPatterns(me);

  const perRepo = await mapLimit(repos, cpuLimit(), async (repo) => {
    const fp = await refsFingerprint(repo);
    const cached = freshCommits(cache, repo, fp);
    if (cached) return cached;
    const recs = await extractRepo(repo, pats, isMe);
    cache.repos[repo] = { refsFingerprint: fp, commits: recs };
    return recs;
  });
  await saveCache(dir, cache);

  const cube = mergeToCube(perRepo);
  const metric: Metric = values.net ? "net" : "authored";
  const lang = values.lang ? resolveLang(values.lang) : undefined;
  const color = process.stdout.isTTY === true && !process.env.NO_COLOR;
  const identities = identityList(me);

  if (values.json) {
    return JSON.stringify({ cube, identities, lang: lang ?? null, metric }, null, 2);
  }

  const width = process.stdout.columns ?? 80;
  const out: string[] = [];

  if (values.date) {
    out.push(title(`Stats for ${values.date}${lang ? ` (${lang})` : ""}`));
    const rows = dayBreakdown(cube, values.date, lang, metric).map((d) => rowFor(d.lang, d.counts, metric, color));
    out.push(rows.length ? renderBars(rows, { width, color }) : "  (no contributions)");
  } else if (values.top) {
    const n = Math.max(parseInt(values.top, 10) || 10, 1);
    out.push(title(`Top ${n} days${lang ? ` (${lang})` : ""}`));
    const rows = topDays(cube, n, lang, metric).map((d) => rowFor(d.date, d.counts, metric, color));
    out.push(rows.length ? renderBars(rows, { width, color }) : "  (no contributions)");
  } else {
    const days = Math.max(parseInt(values.days, 10) || 7, 1);
    out.push(title(`Last ${days} days${lang ? ` (${lang})` : ""}`));
    out.push(renderBars(lastNDays(cube, todayStr(), days, lang).map((d) => rowFor(weekdayLabel(d.date), d.counts, metric, color)), { width, color }));
    out.push("");
    out.push(title("By weekday (all time)"));
    out.push(renderBars(byWeekday(cube, lang).map((w) => rowFor(w.weekday, w.counts, metric, color)), { width, color }));
    out.push("");
    out.push(title("By language (all time)"));
    const langRows = byLanguage(cube, metric).slice(0, 15).map((l) => rowFor(l.lang, l.counts, metric, color));
    out.push(langRows.length ? renderBars(langRows, { width, color }) : "  (no contributions)");
  }

  out.push("");
  out.push(`Counted as you: ${identities.join(", ")}`);
  return out.join("\n");
}

function cpuLimit(): number {
  return Math.max((navigator?.hardwareConcurrency ?? 4) - 1, 1);
}
function title(s: string): string { return `\n ${s}`; }
function weekdayLabel(date: string): string {
  const wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][new Date(date + "T00:00:00Z").getUTCDay()];
  return `${wd} ${date.slice(5)}`;
}
function identityList(me: MeConfig): string[] {
  return [...me.emails, ...me.substrings.map((s) => `*${s}*`)];
}
function resolveLang(input: string): string {
  // accept either a language name or an extension; classify a dummy path for ext
  const byExt = classify(`x.${input.replace(/^\./, "")}`);
  return byExt && byExt !== "Other" ? byExt : input;
}
function renderWhoami(counts: Map<string, number>, isMe: (n: string, e: string) => boolean): string {
  const rows = [...counts.entries()]
    .map(([k, n]) => { const [name, email] = k.split("\t"); return { name, email, n, mine: isMe(name, email) }; })
    .sort((a, b) => b.n - a.n);
  const lines = ["Authors found (✓ = currently counted as you):", ""];
  for (const r of rows.slice(0, 60)) {
    lines.push(`${r.mine ? "✓" : " "} ${String(r.n).padStart(6)}  ${r.name} <${r.email}>`);
  }
  lines.push("", "Add any of YOUR unmatched names/emails to me.json (substrings or emails).");
  return lines.join("\n");
}

// Allow `bun cli.ts` to run directly.
if (import.meta.main) {
  runCli(Bun.argv.slice(2)).then((s) => console.log(s)).catch((e) => { console.error(e); process.exit(1); });
}
