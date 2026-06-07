import { test, expect } from "bun:test";
import {
  mergeToCube, metricValue, lastNDays, byWeekday, byLanguage, topDays, dayBreakdown,
} from "./aggregate";
import type { CommitRecord } from "./types";

const recsRepoA: CommitRecord[] = [
  { sha: "s1", date: "2026-06-01", langs: { TypeScript: { added: 10, updated: 2, deleted: 1 } } }, // Mon
  { sha: "s2", date: "2026-06-02", langs: { Python: { added: 5, updated: 0, deleted: 0 } } },      // Tue
];
const recsRepoB: CommitRecord[] = [
  { sha: "s1", date: "2026-06-01", langs: { TypeScript: { added: 10, updated: 2, deleted: 1 } } }, // DUP sha
  { sha: "s3", date: "2026-06-01", langs: { TypeScript: { added: 3, updated: 0, deleted: 0 } } },
];

test("mergeToCube dedupes by sha across repos", () => {
  const cube = mergeToCube([recsRepoA, recsRepoB]);
  // s1 counted once: TS on 06-01 = 10+3 added (s1 + s3), updated 2
  expect(cube["2026-06-01"].TypeScript).toEqual({ added: 13, updated: 2, deleted: 1 });
  expect(cube["2026-06-02"].Python.added).toBe(5);
});

test("metricValue: authored = added+updated, net = added-deleted", () => {
  const c = { added: 10, updated: 2, deleted: 1 };
  expect(metricValue(c, "authored")).toBe(12);
  expect(metricValue(c, "net")).toBe(9);
});

test("lastNDays returns N descending-from-today rows incl. zero days", () => {
  const cube = mergeToCube([recsRepoA]);
  const rows = lastNDays(cube, "2026-06-03", 3); // Wed back to Mon
  expect(rows.map((r) => r.date)).toEqual(["2026-06-03", "2026-06-02", "2026-06-01"]);
  expect(rows[0].counts.added).toBe(0);     // Wed empty
  expect(rows[2].counts.added).toBe(10);    // Mon
});

test("byWeekday buckets Mon-first", () => {
  const cube = mergeToCube([recsRepoA]);
  const wk = byWeekday(cube);
  expect(wk[0].weekday).toBe("Mon");
  expect(wk[0].counts.added).toBe(10); // 06-01 is a Monday
  expect(wk[1].counts.added).toBe(5);  // 06-02 Tuesday
});

test("byLanguage sorted by authored desc", () => {
  const cube = mergeToCube([recsRepoA]);
  const langs = byLanguage(cube);
  expect(langs[0].lang).toBe("TypeScript"); // 12 authored > Python 5
});

test("topDays returns highest-authored days", () => {
  const cube = mergeToCube([recsRepoA, recsRepoB]);
  const top = topDays(cube, 1);
  expect(top[0].date).toBe("2026-06-01"); // 13+2 authored
});

test("lang filter restricts counts", () => {
  const cube = mergeToCube([recsRepoA]);
  const rows = lastNDays(cube, "2026-06-02", 2, "Python");
  expect(rows[0].counts.added).toBe(5);  // Tue python
  expect(rows[1].counts.added).toBe(0);  // Mon has no python
});

test("dayBreakdown lists languages for a date", () => {
  const cube = mergeToCube([recsRepoA, recsRepoB]);
  const day = dayBreakdown(cube, "2026-06-01");
  expect(day[0].lang).toBe("TypeScript");
  expect(day[0].counts.added).toBe(13);
});
