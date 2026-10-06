// 用法：bun build.mjs —— 把 mascots.js 里的每个变体写成 svg/<id>.svg
import "./mascots.js";
import { mkdirSync, writeFileSync } from "node:fs";
mkdirSync("svg", { recursive: true });
for (const v of globalThis.HarmoniaMascots.variants) {
  writeFileSync(`svg/${v.id}.svg`, globalThis.HarmoniaMascots.svg(v.id, 1024) + "\n");
}
