import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { refsFingerprint, extractRepo, listAuthors, discoverRepos } from "./git";
import { authorPatterns, makeMatcher } from "./identity";

let root: string;
let repo: string;

async function run(cwd: string, ...args: string[]) {
  const p = Bun.spawn(["git", ...args], {
    cwd,
    env: { ...process.env, GIT_AUTHOR_DATE: "2026-06-01T12:00:00+00:00", GIT_COMMITTER_DATE: "2026-06-01T12:00:00+00:00" },
    stdout: "pipe", stderr: "pipe",
  });
  await p.exited;
}

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), "cs-"));
  repo = join(root, "owner", "demo");
  await run(root, "init", "-q", repo);
  await run(repo, "config", "user.name", "Octocat");
  await run(repo, "config", "user.email", "you@example.com");
  await Bun.write(join(repo, "a.ts"), "one\ntwo\nthree\n");
  await run(repo, "add", "a.ts");
  await run(repo, "commit", "-q", "-m", "add a.ts");
  await Bun.write(join(repo, "a.ts"), "one\nTWO\nthree\nfour\n"); // 1 updated + 1 added
  await run(repo, "add", "a.ts");
  await run(repo, "commit", "-q", "-m", "edit a.ts");
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

test("refsFingerprint changes when refs change", async () => {
  const fp1 = await refsFingerprint(repo);
  expect(fp1).toMatch(/^[0-9a-f]{64}$/);
  await run(repo, "branch", "feature");
  const fp2 = await refsFingerprint(repo);
  expect(fp2).not.toBe(fp1);
});

test("extractRepo returns my commit records with correct counts", async () => {
  const me = { substrings: ["octocat"], emails: ["you@example.com"] };
  const recs = await extractRepo(repo, authorPatterns(me), makeMatcher(me));
  const total = recs.reduce(
    (a, r) => {
      for (const c of Object.values(r.langs)) { a.added += c.added; a.updated += c.updated; }
      return a;
    },
    { added: 0, updated: 0 },
  );
  // commit1: +3 ; commit2: 1 updated + 1 added
  expect(total.added).toBe(4);
  expect(total.updated).toBe(1);
});

test("listAuthors counts identities", async () => {
  const authors = await listAuthors(repo);
  expect(authors.get("Octocat\tyou@example.com")).toBe(2);
});

test("discoverRepos finds the nested repo", async () => {
  const repos = await discoverRepos(root);
  expect(repos).toContain(repo);
});
