import { test, expect } from "bun:test";
import { fmt, renderBars, stripAnsi } from "./render";

test("fmt adds thousands separators", () => {
  expect(fmt(1240)).toBe("1,240");
  expect(fmt(42011)).toBe("42,011");
  expect(fmt(0)).toBe("0");
});

test("renderBars: labels, totals, notes present; scales to max", () => {
  const rows = [
    { label: "Mon", segments: [{ value: 980, char: "█", ansi: "" }, { value: 260, char: "▒", ansi: "" }], note: "(+980 ~260)" },
    { label: "Tue", segments: [{ value: 540, char: "█", ansi: "" }, { value: 180, char: "▒", ansi: "" }], note: "(+540 ~180)" },
  ];
  const out = stripAnsi(renderBars(rows, { width: 40, color: false }));
  const lines = out.split("\n");
  expect(lines[0]).toContain("Mon");
  expect(lines[0]).toContain("1,240");
  expect(lines[0]).toContain("(+980 ~260)");
  // Mon total (1240) > Tue total (720) => Mon bar has more block chars
  const blocks = (s: string) => (s.match(/[█▒]/g) ?? []).length;
  expect(blocks(lines[0])).toBeGreaterThan(blocks(lines[1]));
});

test("renderBars handles all-zero rows without crashing", () => {
  const rows = [{ label: "x", segments: [{ value: 0, char: "█", ansi: "" }], note: "" }];
  const out = renderBars(rows, { width: 20, color: false });
  expect(out).toContain("x");
});
