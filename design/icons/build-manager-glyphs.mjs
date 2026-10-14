// 由实例首页（server/src/core/home.ts）的手绘图形生成本机管理页面用的静态 SVG：每个图形一份浅色、一份深色。
// 用法：node build-manager-glyphs.mjs ../../cli/internal/managerui/static
import { writeFileSync } from "node:fs";

const out = process.argv[2];
const themes = {
  "": { k: "#2A2620", g: "#7FAF84", o: "#E8693A", y: "#E9BD52" },
  "-dark": { k: "#F2EDE4", g: "#8DBF92", o: "#F08A5D", y: "#E9BD52" },
};
for (const [suffix, c] of Object.entries(themes)) {
  const strokes = (shapes, width) =>
    `<g fill="none" stroke="${c.k}" stroke-linecap="round" stroke-linejoin="round" filter="url(#sk1)">` +
    `<g stroke-width="${width}">${shapes}</g>` +
    `<g stroke-width="${width * 0.4}" opacity=".5" transform="translate(-.9 .8)">${shapes}</g></g>`;
  const hatch = (shape, pattern) => `<g fill="url(#${pattern})" transform="translate(1.2 1.4)" filter="url(#sk2)">${shape}</g>`;
  const wobble = (id, frequency, seed, scale) =>
    `<filter id="${id}" x="-10%" y="-10%" width="120%" height="120%">` +
    `<feTurbulence type="fractalNoise" baseFrequency="${frequency}" numOctaves="2" seed="${seed}"/>` +
    `<feDisplacementMap in="SourceGraphic" scale="${scale}"/></filter>`;
  const stripes = (id, color) =>
    `<pattern id="${id}" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)">` +
    `<line x1="0" y1="0" x2="0" y2="3.2" stroke="${color}" stroke-width="2"/></pattern>`;
  const defs = `<defs>${wobble("sk1", ".06", 4, "2.4")}${wobble("sk2", ".09", 11, "2.2")}${stripes("hg", c.g)}${stripes("ho", c.o)}${stripes("hy", c.y)}</defs>`;
  const glyph = (fill, pattern, lines) =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">${defs}${hatch(fill, pattern)}${strokes(fill + lines, 3.2)}</svg>\n`;
  const files = {
    phone: glyph(
      `<path d="M36 12 H64 Q70 12 70 18 V82 Q70 88 64 88 H36 Q30 88 30 82 V18 Q30 12 36 12 Z"/>`, "hg",
      `<path d="M45 21 H55"/><path d="M38 38 H45 M49 38 H62 M38 49 H45 M49 49 H58 M38 60 H45 M49 60 H60" stroke-width="2.6"/>`),
    server: glyph(
      `<path d="M16 22 H84 V46 H16 Z"/><path d="M16 54 H84 V78 H16 Z"/>`, "ho",
      `<path d="M27 34 H29 M37 34 H39 M56 34 H73 M27 66 H29 M37 66 H39 M56 66 H73"/>`),
    laptop: glyph(
      `<path d="M24 20 H76 V60 H24 Z"/>`, "hy",
      `<path d="M12 68 H88 L82 78 H18 Z"/><path d="M34 33 L42 40 L34 47 M48 48 H60" stroke-width="2.6"/>`),
    // 文件：与应用图标里的那张纸相同，用于“还没有变量”和拖入文件的提示。
    file: glyph(
      `<path d="M29 14 H59 L73 28 V86 H29 Z"/>`, "hg",
      `<path d="M59 14 V28 H73"/><path d="M38 42 H46 M50 42 H62 M38 54 H46 M50 54 H58 M38 66 H46 M50 66 H60" stroke-width="2.6"/>`),
  };
  for (const [name, svg] of Object.entries(files)) writeFileSync(`${out}/${name}${suffix}.svg`, svg);
}
