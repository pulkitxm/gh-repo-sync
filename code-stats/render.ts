export interface Segment { value: number; char: string; ansi: string }
export interface BarRow { label: string; segments: Segment[]; note?: string }

const RESET = "\x1b[0m";

export function fmt(n: number): string {
  return Math.round(n).toLocaleString("en-US");
}

export function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

export function renderBars(rows: BarRow[], opts?: { width?: number; color?: boolean }): string {
  const color = opts?.color ?? false;
  const width = opts?.width ?? 60;
  const labelW = Math.max(...rows.map((r) => r.label.length), 1);
  const totals = rows.map((r) => r.segments.reduce((a, s) => a + s.value, 0));
  const max = Math.max(...totals, 1);
  const barMax = Math.max(width - labelW - 16, 4);

  return rows
    .map((r, i) => {
      const total = totals[i];
      let bar = "";
      for (const seg of r.segments) {
        const n = Math.round((seg.value / max) * barMax);
        const chunk = seg.char.repeat(n);
        bar += color && seg.ansi ? seg.ansi + chunk + RESET : chunk;
      }
      const label = r.label.padEnd(labelW);
      const note = r.note ? "  " + r.note : "";
      return `${label}  ${bar}  ${fmt(total)}${note}`;
    })
    .join("\n");
}
