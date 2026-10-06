// 用法：bun build-styles.mjs —— 把 styles.js 的九种风格写成 styles/<id>.svg
import "./styles.js";
import { mkdirSync, writeFileSync } from "node:fs";
mkdirSync("styles", { recursive: true });
for (const s of globalThis.HarmoniaStyles.styles) {
  writeFileSync(`styles/${s.id}.svg`, globalThis.HarmoniaStyles.svg(s.id, 1024) + "\n");
}
