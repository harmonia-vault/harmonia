// 用法：bun build-sketch.mjs —— 把 sketch.js 的每个主题写成 sketch/<id>.svg
import "./sketch.js";
import { mkdirSync, writeFileSync } from "node:fs";
mkdirSync("sketch", { recursive: true });
for (const s of globalThis.HarmoniaSketch.subjects) {
  writeFileSync(`sketch/${s.id}.svg`, globalThis.HarmoniaSketch.svg(s.id, 1024) + "\n");
}
