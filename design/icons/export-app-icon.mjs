// 用法：mise run app-icon —— 把手绘「.env 同步」图标导出到 workspace/mobile 的 iOS 与 Android 工程。
// iOS：单张 1024 图标 + 浅色 / 深色 / 着色三种外观（iOS 18 起系统按外观切换）。
// Android：自适应图标（纸底背景层 + 图形前景层 + 单色主题层），以及旧式 ic_launcher。
import "./envsync.js";
import { Resvg } from "@resvg/resvg-js";
import { deflateSync } from "node:zlib";
import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const MOBILE = new URL("../../workspace/mobile/", import.meta.url).pathname;
const IOS_SET = join(MOBILE, "ios/Runner/Assets.xcassets/AppIcon.appiconset");
const ANDROID_RES = join(MOBILE, "android/app/src/main/res");
const E = globalThis.HarmoniaEnvSync;

const render = (svg, size) =>
  new Resvg(svg, { fitTo: { mode: "width", value: size } }).render();

// App Store 要求图标不含 alpha 通道：把 RGBA 像素重新编码成 RGB PNG。
const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};
const opaquePng = (image) => {
  const { width, height, pixels } = image;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 3 + 1)] = 0;
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4, d = y * (width * 3 + 1) + 1 + x * 3;
      raw[d] = pixels[s]; raw[d + 1] = pixels[s + 1]; raw[d + 2] = pixels[s + 2];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
};

// —— iOS ——
const ios = [
  { file: "AppIcon-1024.png", svg: E.svg("sketch-light", null, "l") },
  { file: "AppIcon-1024-dark.png", svg: E.svg("sketch-dark", null, "d"), appearance: "dark" },
  { file: "AppIcon-1024-tinted.png", svg: E.svg("sketch-dark", null, "t", { gray: true }), appearance: "tinted" },
];
for (const f of readdirSync(IOS_SET)) if (f.endsWith(".png")) rmSync(join(IOS_SET, f));
for (const i of ios) writeFileSync(join(IOS_SET, i.file), opaquePng(render(i.svg, 1024)));
writeFileSync(join(IOS_SET, "Contents.json"), JSON.stringify({
  images: ios.map(i => ({
    ...(i.appearance ? { appearances: [{ appearance: "luminosity", value: i.appearance }] } : {}),
    filename: i.file, idiom: "universal", platform: "ios", size: "1024x1024",
  })),
  info: { author: "xcode", version: 1 },
}, null, 2) + "\n");

// —— Android ——
// 自适应图标画布 108dp，可见区约 72dp：让 100 单位的设计正好落在 72dp 可见区，四周各留 25 单位。
const ADAPTIVE = "-25 -25 150 150";
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [d, k] of Object.entries(densities)) {
  const dir = join(ANDROID_RES, `mipmap-${d}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "ic_launcher.png"), render(E.svg("sketch-light", null, "a"), 48 * k).asPng());
  for (const layer of ["bg", "fg", "mono"]) {
    const name = { bg: "background", fg: "foreground", mono: "monochrome" }[layer];
    const svg = E.svg("sketch-light", null, `a${layer}`, { layer, viewBox: ADAPTIVE });
    writeFileSync(join(dir, `ic_launcher_${name}.png`), render(svg, 108 * k).asPng());
  }
}
mkdirSync(join(ANDROID_RES, "mipmap-anydpi-v26"), { recursive: true });
writeFileSync(join(ANDROID_RES, "mipmap-anydpi-v26/ic_launcher.xml"), `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
`);

console.log("iOS:", ios.map(i => i.file).join(", "));
console.log("Android:", Object.keys(densities).join(", "), "+ mipmap-anydpi-v26/ic_launcher.xml");
