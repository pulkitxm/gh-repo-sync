import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { classify } from "./lang";
import type { CommitRecord, LangCounts } from "./types";

const COMMIT_PREFIX = "C\t";

// Drop generated/vendored paths at the GIT level so we never transfer (and never
// buffer) megabytes/gigabytes of diff we'd discard anyway. classify() remains the
// authoritative per-file filter during parsing; these just bound I/O and memory.
const EXCLUDE_PATHSPECS = [
  ":(exclude)**/node_modules/**",
  ":(exclude)**/dist/**",
  ":(exclude)**/build/**",
  ":(exclude)**/vendor/**",
  ":(exclude)**/.next/**",
  ":(exclude)**/out/**",
  ":(exclude)**/coverage/**",
  ":(exclude)**/.turbo/**",
  ":(exclude)**/*.min.js",
  ":(exclude)**/*.min.css",
  ":(exclude)**/package-lock.json",
  ":(exclude)**/yarn.lock",
  ":(exclude)**/pnpm-lock.yaml",
  ":(exclude)**/bun.lockb",
  ":(exclude)**/*.lock",
  ":(exclude)**/go.sum",
  ":(exclude)**/poetry.lock",
  ":(exclude)**/composer.lock",
  ":(exclude)**/Gemfile.lock",
];

function emptyCounts(): LangCounts {
  return { added: 0, updated: 0, deleted: 0 };
}

export interface LogParser {
  pushLine(line: string): void;
  finish(): CommitRecord[];
}

// Stateful, incremental diff-log parser. Feed it one line at a time (from a string
// or a stream); it accumulates only integer counts, so memory stays bounded
// regardless of how large the underlying `git log -p` output is.
export function createLogParser(
  isMe: (name: string, email: string) => boolean,
): LogParser {
  const out: CommitRecord[] = [];

  let cur: CommitRecord | null = null;
  let curKeep = false; // current commit matches isMe
  let inHunk = false;
  let curLang: string | null = null;
  let fallbackPath = ""; // from '--- a/<path>'
  let minus = 0;
  let plus = 0;

  const flushHunk = () => {
    if (!inHunk) return;
    if (cur && curKeep && curLang && (minus || plus)) {
      const c = (cur.langs[curLang] ??= emptyCounts());
      c.updated += Math.min(minus, plus);
      c.added += Math.max(plus - minus, 0);
      c.deleted += Math.max(minus - plus, 0);
    }
    minus = 0;
    plus = 0;
  };

  const flushCommit = () => {
    flushHunk();
    if (cur && curKeep) out.push(cur);
    cur = null;
    curKeep = false;
    inHunk = false;
    curLang = null;
    fallbackPath = "";
  };

  const pushLine = (line: string) => {
    if (line.startsWith(COMMIT_PREFIX)) {
      flushCommit();
      // C \t sha \t isoDate \t name \t email
      const parts = line.split("\t");
      const sha = parts[1] ?? "";
      const iso = parts[2] ?? "";
      const name = parts[3] ?? "";
      const email = parts[4] ?? "";
      curKeep = isMe(name, email);
      cur = { sha, date: iso.slice(0, 10), langs: {} };
      return;
    }
    if (line.startsWith("diff --git ")) {
      flushHunk();
      inHunk = false;
      curLang = null;
      fallbackPath = "";
      return;
    }
    if (!inHunk && line.startsWith("--- ")) {
      const p = line.slice(4);
      fallbackPath = p === "/dev/null" ? "" : p.replace(/^a\//, "");
      return;
    }
    if (!inHunk && line.startsWith("+++ ")) {
      const p = line.slice(4);
      const path = p === "/dev/null" ? fallbackPath : p.replace(/^b\//, "");
      curLang = path ? classify(path) : null;
      return;
    }
    if (line.startsWith("@@")) {
      flushHunk();
      inHunk = true;
      return;
    }
    if (inHunk) {
      if (line.startsWith("+")) plus++;
      else if (line.startsWith("-")) minus++;
      // anything else inside -U0 output (e.g. '\ No newline') is ignored
    }
  };

  return {
    pushLine,
    finish() {
      flushCommit();
      return out;
    },
  };
}

export function parseLog(
  text: string,
  isMe: (name: string, email: string) => boolean,
): CommitRecord[] {
  const parser = createLogParser(isMe);
  for (const line of text.split("\n")) parser.pushLine(line);
  return parser.finish();
}

// Yield git stdout one line at a time without ever holding the whole output in
// memory. Buffers at most one in-flight line.
async function* gitLines(cwd: string, args: string[]): AsyncGenerator<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "ignore" });
  const decoder = new TextDecoder();
  let buf = "";
  // @ts-expect-error Bun's subprocess stdout ReadableStream is async-iterable
  for await (const chunk of proc.stdout) {
    buf += decoder.decode(chunk, { stream: true });
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const line of parts) yield line;
  }
  buf += decoder.decode();
  if (buf.length) yield buf;
  await proc.exited;
}

async function gitText(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "ignore" });
  const text = await new Response(proc.stdout).text();
  await proc.exited;
  return text;
}

export async function refsFingerprint(repoPath: string): Promise<string> {
  const refs = await gitText(repoPath, ["for-each-ref", "--format=%(objectname) %(refname)"]);
  const sorted = refs.split("\n").filter(Boolean).sort().join("\n");
  const h = new Bun.CryptoHasher("sha256");
  h.update(sorted);
  return h.digest("hex");
}

export async function extractRepo(
  repoPath: string,
  authorPats: string[],
  isMe: (name: string, email: string) => boolean,
): Promise<CommitRecord[]> {
  const args = [
    "log", "--all", "--no-merges",
    ...authorPats.flatMap((p) => ["--author", p]),
    "--pretty=format:C%x09%H%x09%aI%x09%an%x09%ae",
    "-p", "-U0", "-M", "-C",
    "--", ".", ...EXCLUDE_PATHSPECS,
  ];
  const parser = createLogParser(isMe);
  for await (const line of gitLines(repoPath, args)) parser.pushLine(line);
  return parser.finish();
}

export async function listAuthors(repoPath: string): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  for await (const line of gitLines(repoPath, [
    "log", "--all", "--no-merges", "--pretty=format:%an%x09%ae",
  ])) {
    if (!line) continue;
    counts.set(line, (counts.get(line) ?? 0) + 1);
  }
  return counts;
}

// owner/repo layout: <root>/<owner>/<repo>/.git
export async function discoverRepos(root: string): Promise<string[]> {
  const repos: string[] = [];
  if (!existsSync(root)) return repos;
  for (const owner of readdirSync(root, { withFileTypes: true })) {
    if (!owner.isDirectory() || owner.name.startsWith(".")) continue;
    const ownerPath = join(root, owner.name);
    for (const child of readdirSync(ownerPath, { withFileTypes: true })) {
      if (!child.isDirectory()) continue;
      const repoPath = join(ownerPath, child.name);
      if (existsSync(join(repoPath, ".git"))) repos.push(repoPath);
    }
  }
  return repos;
}
