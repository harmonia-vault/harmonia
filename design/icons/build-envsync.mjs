// 用法：bun build-envsync.mjs —— 把 envsync.js 的所有版本写成 envsync/<id>.svg
import "./envsync.js";
import { mkdirSync, writeFileSync } from "node:fs";
mkdirSync("envsync", { recursive: true });
for (const v of globalThis.HarmoniaEnvSync.variants) {
  writeFileSync(`envsync/${v.id}.svg`, globalThis.HarmoniaEnvSync.svg(v.id, 1024) + "\n");
}
