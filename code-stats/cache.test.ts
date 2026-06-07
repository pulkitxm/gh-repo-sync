import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadCache, saveCache, freshCommits, emptyCache } from "./cache";
import type { CacheFile, CommitRecord } from "./types";

let dir = "";
afterEach(() => { if (dir) rmSync(dir, { recursive: true, force: true }); dir = ""; });

const rec: CommitRecord = { sha: "x", date: "2026-06-01", langs: {} };

test("load returns empty cache when file missing", async () => {
  dir = mkdtempSync(join(tmpdir(), "cc-"));
  const c = await loadCache(dir);
  expect(c).toEqual(emptyCache());
});

test("save then load round-trips", async () => {
  dir = mkdtempSync(join(tmpdir(), "cc-"));
  const c: CacheFile = { version: 1, repos: { "/r": { refsFingerprint: "fp1", commits: [rec] } } };
  await saveCache(dir, c);
  const back = await loadCache(dir);
  expect(back).toEqual(c);
});

test("freshCommits returns cached commits when fingerprint matches", () => {
  const c: CacheFile = { version: 1, repos: { "/r": { refsFingerprint: "fp1", commits: [rec] } } };
  expect(freshCommits(c, "/r", "fp1")).toEqual([rec]);
  expect(freshCommits(c, "/r", "fp2")).toBeNull();
  expect(freshCommits(c, "/other", "fp1")).toBeNull();
});
