import { test, expect } from "bun:test";
import { classify, isGenerated } from "./lang";

test("maps common extensions to languages", () => {
  expect(classify("src/app.ts")).toBe("TypeScript");
  expect(classify("src/app.tsx")).toBe("TSX");
  expect(classify("main.py")).toBe("Python");
  expect(classify("lib.rs")).toBe("Rust");
  expect(classify("index.js")).toBe("JavaScript");
  expect(classify("style.css")).toBe("CSS");
  expect(classify("README.md")).toBe("Markdown");
});

test("recognizes special basenames", () => {
  expect(classify("Dockerfile")).toBe("Dockerfile");
  expect(classify("path/to/Makefile")).toBe("Makefile");
});

test("unknown extension -> Other (still counted)", () => {
  expect(classify("data.weirdext")).toBe("Other");
  expect(classify("LICENSE")).toBe("Other");
});

test("generated/vendored files -> null (excluded)", () => {
  expect(classify("package-lock.json")).toBeNull();
  expect(classify("frontend/yarn.lock")).toBeNull();
  expect(classify("a/bun.lockb")).toBeNull();
  expect(classify("Cargo.lock")).toBeNull();
  expect(classify("app/dist/bundle.js")).toBeNull();
  expect(classify("x/node_modules/y/z.js")).toBeNull();
  expect(classify("public/app.min.js")).toBeNull();
  expect(classify("vendor/foo.go")).toBeNull();
});

test("isGenerated exposed for reuse", () => {
  expect(isGenerated("a/b/.next/c.js")).toBe(true);
  expect(isGenerated("src/app.ts")).toBe(false);
});
