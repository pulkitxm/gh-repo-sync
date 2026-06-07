import { existsSync } from "node:fs";
import { join } from "node:path";
import type { MeConfig } from "./types";

// Placeholder seed — overridden by your gitignored me.json (run --whoami to
// discover the names/emails to put there).
export const DEFAULT_ME: MeConfig = {
  substrings: ["octocat"],
  emails: ["you@example.com"],
};

export function makeMatcher(me: MeConfig): (name: string, email: string) => boolean {
  const subs = me.substrings.map((s) => s.toLowerCase());
  const emails = new Set(me.emails.map((e) => e.toLowerCase()));
  return (name: string, email: string) => {
    const e = email.toLowerCase();
    if (emails.has(e)) return true;
    const hay = (name + " " + email).toLowerCase();
    return subs.some((s) => hay.includes(s));
  };
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Coarse git --author prefilter values (a SUPERSET of makeMatcher).
export function authorPatterns(me: MeConfig): string[] {
  return [...me.substrings, ...me.emails].map(escapeRegex);
}

export async function loadMe(dir: string): Promise<MeConfig> {
  const path = join(dir, "me.json");
  if (!existsSync(path)) {
    await Bun.write(path, JSON.stringify(DEFAULT_ME, null, 2) + "\n");
    return DEFAULT_ME;
  }
  const raw = (await Bun.file(path).json()) as Partial<MeConfig>;
  return {
    substrings: raw.substrings ?? DEFAULT_ME.substrings,
    emails: raw.emails ?? DEFAULT_ME.emails,
  };
}
