export interface LangCounts { added: number; updated: number; deleted: number }
export interface CommitRecord { sha: string; date: string; langs: Record<string, LangCounts> }
export interface RepoCache { refsFingerprint: string; commits: CommitRecord[] }
export interface CacheFile { version: number; repos: Record<string, RepoCache> }
export interface MeConfig { substrings: string[]; emails: string[] }
export type Metric = "authored" | "net";
export type Cube = Record<string, Record<string, LangCounts>>;
