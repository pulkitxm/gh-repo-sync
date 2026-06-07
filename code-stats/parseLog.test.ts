import { test, expect } from "bun:test";
import { parseLog } from "./git";

const isMe = (_n: string, _e: string) => true;

// pretty format used by extractRepo: C \t sha \t isoDate \t name \t email
function commit(sha: string, date: string, body: string) {
  return `C\t${sha}\t${date}T12:00:00+05:30\tPulkit\tp@x.com\n${body}`;
}

test("pure additions: new file", () => {
  const text = commit("a1", "2026-06-01",
`diff --git a/src/app.ts b/src/app.ts
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/src/app.ts
@@ -0,0 +1,3 @@
+line1
+line2
+line3
`);
  const recs = parseLog(text, isMe);
  expect(recs).toHaveLength(1);
  expect(recs[0].langs.TypeScript).toEqual({ added: 3, updated: 0, deleted: 0 });
  expect(recs[0].date).toBe("2026-06-01");
});

test("edit = updated (min of -/+ in a hunk)", () => {
  const text = commit("a2", "2026-06-02",
`diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,2 +1,2 @@
-old1
-old2
+new1
+new2
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs.TypeScript).toEqual({ added: 0, updated: 2, deleted: 0 });
});

test("mixed hunk: 1 deleted, 3 added -> 1 updated + 2 added", () => {
  const text = commit("a3", "2026-06-03",
`diff --git a/x.py b/x.py
index 1..2 100644
--- a/x.py
+++ b/x.py
@@ -1 +1,3 @@
-old
+a
+b
+c
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs.Python).toEqual({ added: 2, updated: 1, deleted: 0 });
});

test("pure deletion file (+++ /dev/null) uses --- path", () => {
  const text = commit("a4", "2026-06-04",
`diff --git a/gone.go b/gone.go
deleted file mode 100644
index 1..0
--- a/gone.go
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs.Go).toEqual({ added: 0, updated: 0, deleted: 2 });
});

test("deleted CONTENT line starting with --- is not mistaken for a header", () => {
  // a SQL migration deleting a line whose text is '-- AlterTable'
  const text = commit("a5", "2026-06-05",
`diff --git a/m.sql b/m.sql
index 1..2 100644
--- a/m.sql
+++ b/m.sql
@@ -1 +1 @@
--- AlterTable
+-- CreateTable
`);
  const recs = parseLog(text, isMe);
  // one '-' line and one '+' line inside the hunk => 1 updated
  expect(recs[0].langs.SQL).toEqual({ added: 0, updated: 1, deleted: 0 });
});

test("pure rename (no hunk) counts nothing", () => {
  const text = commit("a6", "2026-06-06",
`diff --git a/old.ts b/new.ts
similarity index 100%
rename from old.ts
rename to new.ts
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs).toEqual({});
});

test("generated file is skipped", () => {
  const text = commit("a7", "2026-06-06",
`diff --git a/package-lock.json b/package-lock.json
index 1..2 100644
--- a/package-lock.json
+++ b/package-lock.json
@@ -1,0 +1,500 @@
+lots
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs).toEqual({});
});

test("multi-file commit aggregates per language", () => {
  const text = commit("a8", "2026-06-06",
`diff --git a/a.ts b/a.ts
index 1..2 100644
--- a/a.ts
+++ b/a.ts
@@ -0,0 +1,2 @@
+x
+y
diff --git a/b.py b/b.py
index 1..2 100644
--- a/b.py
+++ b/b.py
@@ -0,0 +1 @@
+z
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs.TypeScript.added).toBe(2);
  expect(recs[0].langs.Python.added).toBe(1);
});

test("binary file (no +/- lines) counts nothing", () => {
  const text = commit("a9", "2026-06-06",
`diff --git a/img.png b/img.png
index 1..2 100644
Binary files a/img.png and b/img.png differ
`);
  const recs = parseLog(text, isMe);
  expect(recs[0].langs).toEqual({});
});

test("isMe filter excludes non-matching commits", () => {
  const text =
`C\tb1\t2026-06-06T12:00:00Z\tStranger\ts@x.com
diff --git a/a.ts b/a.ts
index 1..2 100644
--- a/a.ts
+++ b/a.ts
@@ -0,0 +1 @@
+x
`;
  const recs = parseLog(text, (_n, e) => e === "p@x.com");
  expect(recs).toHaveLength(0);
});
