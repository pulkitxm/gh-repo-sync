import { test, expect } from "bun:test";
import { parseLog, createLogParser } from "./git";

const isMe = (_n: string, _e: string) => true;

const SAMPLE =
`C\ta1\t2026-06-01T12:00:00+05:30\tPulkit\tp@x.com
diff --git a/src/app.ts b/src/app.ts
index 1..2 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,2 +1,3 @@
-old
+new
+extra
diff --git a/x.py b/x.py
index 1..2 100644
--- a/x.py
+++ b/x.py
@@ -0,0 +1 @@
+z
C\ta2\t2026-06-02T09:00:00Z\tPulkit\tp@x.com
diff --git a/m.sql b/m.sql
index 1..2 100644
--- a/m.sql
+++ b/m.sql
@@ -1 +1 @@
--- AlterTable
+-- CreateTable
`;

// Feed the parser in arbitrary byte-sized chunks, splitting on newlines exactly
// the way gitLines() does, to prove streaming == whole-string parsing.
function parseChunked(text: string, chunkSize: number) {
  const parser = createLogParser(isMe);
  let buf = "";
  for (let i = 0; i < text.length; i += chunkSize) {
    buf += text.slice(i, i + chunkSize);
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const line of parts) parser.pushLine(line);
  }
  if (buf.length) parser.pushLine(buf);
  return parser.finish();
}

test("streaming in tiny chunks equals parseLog on the whole string", () => {
  const whole = parseLog(SAMPLE, isMe);
  for (const size of [1, 3, 7, 16, 64, 1024]) {
    expect(parseChunked(SAMPLE, size)).toEqual(whole);
  }
});

test("counts survive chunk boundaries", () => {
  const recs = parseChunked(SAMPLE, 5);
  expect(recs).toHaveLength(2);
  expect(recs[0].langs.TypeScript).toEqual({ added: 1, updated: 1, deleted: 0 });
  expect(recs[0].langs.Python).toEqual({ added: 1, updated: 0, deleted: 0 });
  expect(recs[1].langs.SQL).toEqual({ added: 0, updated: 1, deleted: 0 });
});
