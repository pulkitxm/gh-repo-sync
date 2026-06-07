import { test, expect } from "bun:test";
import type { CommitRecord, LangCounts } from "./types";

test("types are usable", () => {
  const c: LangCounts = { added: 1, updated: 2, deleted: 3 };
  const r: CommitRecord = { sha: "abc", date: "2026-06-07", langs: { TypeScript: c } };
  expect(r.langs.TypeScript.added).toBe(1);
});
