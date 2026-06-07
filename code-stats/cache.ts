import { existsSync } from "node:fs";
import { join } from "node:path";
import type { CacheFile, CommitRecord } from "./types";

const CACHE_VERSION = 1;

export function emptyCache(): CacheFile {
  return { version: CACHE_VERSION, repos: {} };
}

export async function loadCache(dir: string): Promise<CacheFile> {
  const path = join(dir, "cache.json");
  if (!existsSync(path)) return emptyCache();
  try {
    const c = (await Bun.file(path).json()) as CacheFile;
    if (c.version !== CACHE_VERSION || !c.repos) return emptyCache();
    return c;
  } catch {
    return emptyCache();
  }
}

export async function saveCache(dir: string, cache: CacheFile): Promise<void> {
  await Bun.write(join(dir, "cache.json"), JSON.stringify(cache));
}

export function freshCommits(
  cache: CacheFile,
  repoPath: string,
  fingerprint: string,
): CommitRecord[] | null {
  const entry = cache.repos[repoPath];
  if (entry && entry.refsFingerprint === fingerprint) return entry.commits;
  return null;
}
