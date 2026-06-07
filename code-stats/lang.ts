const LOCK_BASENAMES = new Set([
  "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
  "cargo.lock", "poetry.lock", "composer.lock", "gemfile.lock", "go.sum",
]);

const GENERATED_DIR_SEGMENTS = [
  "node_modules", "dist", "build", "vendor", ".next", "out", "coverage", ".turbo",
];

const SPECIAL_BASENAMES: Record<string, string> = {
  dockerfile: "Dockerfile",
  makefile: "Makefile",
  "cmakelists.txt": "CMake",
};

const EXT_LANG: Record<string, string> = {
  ts: "TypeScript", tsx: "TSX", js: "JavaScript", jsx: "JSX", mjs: "JavaScript", cjs: "JavaScript",
  py: "Python", rb: "Ruby", go: "Go", rs: "Rust", java: "Java", kt: "Kotlin", swift: "Swift",
  c: "C", h: "C/C++ Header", hpp: "C/C++ Header", cpp: "C++", cc: "C++", cxx: "C++", cs: "C#",
  php: "PHP", scala: "Scala", dart: "Dart", lua: "Lua", r: "R", jl: "Julia", zig: "Zig",
  sh: "Shell", bash: "Shell", zsh: "Shell", ps1: "PowerShell",
  html: "HTML", css: "CSS", scss: "SCSS", sass: "SCSS", less: "Less", vue: "Vue", svelte: "Svelte",
  json: "JSON", yaml: "YAML", yml: "YAML", toml: "TOML", xml: "XML", csv: "CSV",
  md: "Markdown", mdx: "MDX", txt: "Text", sql: "SQL", proto: "Protobuf", graphql: "GraphQL", gql: "GraphQL",
  ipynb: "Jupyter Notebook",
};

export function isGenerated(path: string): boolean {
  const lower = path.toLowerCase();
  const base = lower.split("/").pop() ?? lower;
  if (LOCK_BASENAMES.has(base)) return true;
  if (base.endsWith(".min.js") || base.endsWith(".min.css")) return true;
  const segs = lower.split("/");
  return GENERATED_DIR_SEGMENTS.some((g) => segs.includes(g));
}

export function classify(path: string): string | null {
  if (isGenerated(path)) return null;
  const base = (path.split("/").pop() ?? path).toLowerCase();
  if (SPECIAL_BASENAMES[base]) return SPECIAL_BASENAMES[base];
  const dot = base.lastIndexOf(".");
  if (dot <= 0) return "Other"; // no extension (LICENSE) or dotfile
  const ext = base.slice(dot + 1);
  return EXT_LANG[ext] ?? "Other";
}
