// Harmonia 吉祥物 SVG 生成器：浏览器里挂到 globalThis.HarmoniaMascots，bun 里由 build.mjs 调用写出 .svg 文件。
// 所有图形在 100×100 画布内，满版方形背景（不带圆角遮罩，交给系统裁切）。
(() => {
  const grad = (id, [c1, c2], x1, y1, x2, y2) =>
    `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}"><stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/></linearGradient>`;

  const wrap = (body, size) =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"${size ? ` width="${size}" height="${size}"` : ""}>${body}</svg>`;

  // 信鸽：侧身，胸前大块翅膀是信封，折线是封口
  const pigeon = (p, id, size) => wrap(`
  <defs>${grad(`${id}-a`, p.main, 10, 10, 95, 110)}${grad(`${id}-b`, p.second, 5, 55, 60, 105)}</defs>
  <rect width="100" height="100" fill="${p.bg}"/>
  <g fill="url(#${id}-a)">
    <ellipse cx="42" cy="88" rx="44" ry="34"/>
    <path d="M50 64 C50 46 54 34 64 30 C74 28 80 40 78 54 C76 66 72 72 66 76 Z"/>
    <circle cx="65" cy="36" r="18"/>
  </g>
  <rect x="78" y="35" width="10" height="7" rx="3.5" transform="rotate(18 78 38.5)" fill="${p.face}"/>
  <circle cx="69" cy="32" r="3.8" fill="${p.face}"/>
  <path d="M-4 74 C10 60 40 60 54 72 C60 78 56 92 44 98 C30 104 6 104 -4 98 Z" fill="url(#${id}-b)"/>
  <path d="M12 76 L28 85 L44 76" fill="none" stroke="${p.detail}" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/>`, size);

  // 松鼠：抱着一颗橡果（变量），身后一条卷尾
  const squirrel = (p, id, size) => wrap(`
  <defs>${grad(`${id}-a`, p.main, 5, 5, 95, 105)}${grad(`${id}-b`, p.second, 22, 72, 46, 100)}</defs>
  <rect width="100" height="100" fill="${p.bg}"/>
  <path d="M70 108 C64 78 62 50 72 32 C78 21 90 21 89 34" fill="none" stroke="url(#${id}-a)" stroke-width="27" stroke-linecap="round"/>
  <g fill="url(#${id}-a)">
    <ellipse cx="36" cy="102" rx="32" ry="30"/>
    <ellipse cx="19" cy="33" rx="7.5" ry="11" transform="rotate(-14 19 33)"/>
    <ellipse cx="47" cy="33" rx="7.5" ry="11" transform="rotate(14 47 33)"/>
    <ellipse cx="33" cy="56" rx="25" ry="21"/>
  </g>
  <g fill="url(#${id}-b)">
    <rect x="31.8" y="71" width="4.4" height="7" rx="2.2"/>
    <ellipse cx="34" cy="89" rx="9.5" ry="10"/>
    <ellipse cx="34" cy="80" rx="12" ry="5.6"/>
  </g>
  <circle cx="24" cy="54" r="3.8" fill="${p.face}"/>
  <circle cx="42" cy="54" r="3.8" fill="${p.face}"/>
  <path d="M29.5 61 Q33 64.5 36.5 61" fill="none" stroke="${p.face}" stroke-width="2.6" stroke-linecap="round"/>`, size);

  // 小锁精：锁身是脸，钥匙孔是嘴，从右下角探出
  const lock = (p, id, size) => wrap(`
  <defs>${grad(`${id}-a`, p.main, 30, 5, 85, 60)}${grad(`${id}-b`, p.second, 10, 30, 95, 110)}</defs>
  <rect width="100" height="100" fill="${p.bg}"/>
  <path d="M40 54 V36 A18 18 0 0 1 76 36 V54" fill="none" stroke="url(#${id}-a)" stroke-width="12" stroke-linecap="round"/>
  <rect x="21" y="46" width="74" height="70" rx="19" fill="url(#${id}-b)"/>
  <circle cx="46" cy="71" r="5.6" fill="${p.face}"/>
  <circle cx="70" cy="71" r="5.6" fill="${p.face}"/>
  <circle cx="58" cy="82" r="4.4" fill="${p.face}"/>
  <rect x="55.9" y="82" width="4.2" height="9" rx="2.1" fill="${p.face}"/>`, size);

  const cream = ["#FFF9EE", "#EADFCB"], charcoal = ["#3D352C", "#241F1A"];
  const variants = [
    { id: "pigeon-forest", kind: "pigeon", build: pigeon, p: { bg: "#3D5A4A", main: cream, second: charcoal, face: "#27221C", detail: "#F6EFE2" } },
    { id: "pigeon-terracotta", kind: "pigeon", build: pigeon, p: { bg: "#D0603C", main: cream, second: charcoal, face: "#27221C", detail: "#F6EFE2" } },
    { id: "squirrel-forest", kind: "squirrel", build: squirrel, p: { bg: "#2F4A3E", main: ["#EA8752", "#D46A36"], second: charcoal, face: "#27221C" } },
    { id: "squirrel-ink", kind: "squirrel", build: squirrel, p: { bg: "#231F1A", main: ["#EA8752", "#D46A36"], second: ["#5A4A3C", "#3F3329"], face: "#27221C" } },
    { id: "lock-terracotta", kind: "lock", build: lock, p: { bg: "#D0603C", main: ["#F7D478", "#E8BB48"], second: ["#3B342C", "#221D18"], face: "#F0C75A" } },
    { id: "lock-forest", kind: "lock", build: lock, p: { bg: "#3D5A4A", main: ["#EE8A5E", "#D0603C"], second: cream, face: "#B8461F" } },
  ];

  globalThis.HarmoniaMascots = {
    variants,
    svg: (variantId, size, uid = variantId) => {
      const v = variants.find(x => x.id === variantId);
      return v.build(v.p, uid, size);
    },
  };
})();
