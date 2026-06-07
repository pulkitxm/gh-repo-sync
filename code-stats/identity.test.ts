import { test, expect } from "bun:test";
import { makeMatcher, authorPatterns, DEFAULT_ME } from "./identity";

const me = { substrings: ["octocat"], emails: ["you@example.com"] };

test("matches by substring in name or email (case-insensitive)", () => {
  const isMe = makeMatcher(me);
  expect(isMe("Octocat Smith", "whatever@x.com")).toBe(true);
  expect(isMe("someone", "12345+octocat@users.noreply.github.com")).toBe(true);
  expect(isMe("OCTOCAT", "X@Y.com")).toBe(true);
});

test("matches by exact email", () => {
  const isMe = makeMatcher(me);
  expect(isMe("Old Name", "you@example.com")).toBe(true);
});

test("does not match unrelated authors", () => {
  const isMe = makeMatcher(me);
  expect(isMe("Jarred Sumner", "jarred@jarredsumner.com")).toBe(false);
});

test("authorPatterns escapes regex metacharacters for git --author", () => {
  const pats = authorPatterns(me);
  expect(pats).toContain("octocat");
  expect(pats).toContain("you@example\\.com");
});

test("DEFAULT_ME has sensible seed", () => {
  expect(DEFAULT_ME.substrings).toContain("octocat");
  expect(DEFAULT_ME.emails).toContain("you@example.com");
});
