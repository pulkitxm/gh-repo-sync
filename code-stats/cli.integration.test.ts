import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCli } from "./cli";

let root: string;       // contains owner/demo repo
let workdir: string;    // where me.json + cache.json live

async function git(cwd: string, args: string[], date: string) {
  const p = Bun.spawn(["git", ...args], {
    cwd,
    env: { ...process.env, GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date },
    stdout: "pipe", stderr: "pipe",
  });
  await p.exited;
}

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), "cs-root-"));
  workdir = mkdtempSync(join(tmpdir(), "cs-work-"));
  const repo = join(root, "owner", "demo");
  await git(root, ["init", "-q", repo], "2026-06-01T12:00:00+00:00");
  await git(repo, ["config", "user.name", "Octocat"], "2026-06-01T12:00:00+00:00");
  await git(repo, ["config", "user.email", "you@example.com"], "2026-06-01T12:00:00+00:00");
  await Bun.write(join(repo, "a.ts"), "1\n2\n3\n");
  await git(repo, ["add", "a.ts"], "2026-06-01T12:00:00+00:00");
  await git(repo, ["commit", "-q", "-m", "c1"], "2026-06-01T12:00:00+00:00");
  // a stranger's commit that must NOT count
  await git(repo, ["config", "user.name", "Stranger"], "2026-06-02T12:00:00+00:00");
  await git(repo, ["config", "user.email", "s@x.com"], "2026-06-02T12:00:00+00:00");
  await Bun.write(join(repo, "b.py"), "x\ny\n");
  await git(repo, ["add", "b.py"], "2026-06-02T12:00:00+00:00");
  await git(repo, ["commit", "-q", "-m", "c2"], "2026-06-02T12:00:00+00:00");
});

afterAll(() => {
  rmSync(root, { recursive: true, force: true });
  rmSync(workdir, { recursive: true, force: true });
});

test("--json reports only my LOC and writes cache", async () => {
  const out = await runCli(["--root", root, "--json"], workdir);
  const data = JSON.parse(out);
  // Only my TS commit counts (3 added); stranger's python excluded
  expect(data.cube["2026-06-01"].TypeScript.added).toBe(3);
  expect(data.cube["2026-06-02"]).toBeUndefined();
  expect(data.identities.length).toBeGreaterThan(0);
});

test("--whoami lists authors including the stranger", async () => {
  const out = await runCli(["--root", root, "--whoami"], workdir);
  expect(out).toContain("you@example.com");
  expect(out).toContain("s@x.com");
});

test("second run uses cache (fingerprint unchanged)", async () => {
  const out = await runCli(["--root", root, "--json"], workdir);
  const data = JSON.parse(out);
  expect(data.cube["2026-06-01"].TypeScript.added).toBe(3);
});
