import type { CommitRecord, Cube, LangCounts, Metric } from "./types";

function add(into: LangCounts, c: LangCounts) {
  into.added += c.added; into.updated += c.updated; into.deleted += c.deleted;
}
function zero(): LangCounts { return { added: 0, updated: 0, deleted: 0 }; }

export function mergeToCube(recordsByRepo: CommitRecord[][]): Cube {
  const cube: Cube = {};
  const seen = new Set<string>();
  for (const recs of recordsByRepo) {
    for (const r of recs) {
      if (seen.has(r.sha)) continue;
      seen.add(r.sha);
      const day = (cube[r.date] ??= {});
      for (const [lang, c] of Object.entries(r.langs)) {
        add((day[lang] ??= zero()), c);
      }
    }
  }
  return cube;
}

export function metricValue(c: LangCounts, metric: Metric): number {
  return metric === "net" ? c.added - c.deleted : c.added + c.updated;
}

// Sum a day's languages, optionally restricted to one language.
function dayCounts(cube: Cube, date: string, lang?: string): LangCounts {
  const day = cube[date];
  const total = zero();
  if (!day) return total;
  if (lang) { if (day[lang]) add(total, day[lang]); return total; }
  for (const c of Object.values(day)) add(total, c);
  return total;
}

function shiftDate(date: string, deltaDays: number): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return d.toISOString().slice(0, 10);
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function lastNDays(cube: Cube, today: string, n: number, lang?: string) {
  const rows: { date: string; counts: LangCounts }[] = [];
  for (let i = 0; i < n; i++) {
    const date = shiftDate(today, -i);
    rows.push({ date, counts: dayCounts(cube, date, lang) });
  }
  return rows;
}

export function byWeekday(cube: Cube, lang?: string) {
  const buckets: LangCounts[] = Array.from({ length: 7 }, zero);
  for (const date of Object.keys(cube)) {
    const wd = new Date(date + "T00:00:00Z").getUTCDay();
    add(buckets[wd], dayCounts(cube, date, lang));
  }
  // Mon-first order
  const order = [1, 2, 3, 4, 5, 6, 0];
  return order.map((wd) => ({ weekday: WEEKDAYS[wd], counts: buckets[wd] }));
}

export function byLanguage(cube: Cube, metric: Metric = "authored") {
  const totals: Record<string, LangCounts> = {};
  for (const day of Object.values(cube)) {
    for (const [lang, c] of Object.entries(day)) add((totals[lang] ??= zero()), c);
  }
  return Object.entries(totals)
    .map(([lang, counts]) => ({ lang, counts }))
    .sort((a, b) => metricValue(b.counts, metric) - metricValue(a.counts, metric));
}

export function topDays(cube: Cube, n: number, lang?: string, metric: Metric = "authored") {
  return Object.keys(cube)
    .map((date) => ({ date, counts: dayCounts(cube, date, lang) }))
    .sort((a, b) => metricValue(b.counts, metric) - metricValue(a.counts, metric))
    .slice(0, n);
}

export function dayBreakdown(cube: Cube, date: string, lang?: string, metric: Metric = "authored") {
  const day = cube[date] ?? {};
  return Object.entries(day)
    .filter(([l]) => !lang || l === lang)
    .map(([lang, counts]) => ({ lang, counts }))
    .sort((a, b) => metricValue(b.counts, metric) - metricValue(a.counts, metric));
}
