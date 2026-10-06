// Harmonia「.env 同步」图标：同一主题，App 现有风格（砂岩 Bento）、手绘风格各三版，以及四个介于两者之间的融合版。
// 浏览器里挂到 globalThis.HarmoniaEnvSync；bun build-envsync.mjs 写出 envsync/<id>.svg。
(() => {
  const FILE = "M29 22 H59 L71 34 V78 H29 Z";
  const ARROWS = `<path d="M63 73 A7.5 7.5 0 0 1 77 72"/><path d="M77.5 67.5 V72.5 H72.5"/><path d="M77 79 A7.5 7.5 0 0 1 63 80"/><path d="M62.5 84.5 V79.5 H67.5"/>`;

  // —— App 风格：纸米底、墨色描边、奶油黄 / 灰绿值、陶橙同步章 ——
  const app = (t) => (u) => `
    <rect width="100" height="100" fill="${t.bg}"/>
    <g stroke-linejoin="round" stroke-linecap="round">
      <path d="${FILE}" fill="${t.card}" stroke="${t.line}" stroke-width="3"/>
      <path d="M59 22 V30 Q59 34 63 34 H71" fill="${t.fold}" stroke="${t.line}" stroke-width="3"/>
      <g stroke="${t.line}" stroke-width="1.6">
        <rect x="37" y="39" width="10" height="5.5" rx="2.75" fill="${t.key}" stroke="none"/>
        <rect x="50" y="39" width="13" height="5.5" rx="2.75" fill="${t.v1}"/>
        <rect x="37" y="49.5" width="10" height="5.5" rx="2.75" fill="${t.key}" stroke="none"/>
        <rect x="50" y="49.5" width="9" height="5.5" rx="2.75" fill="${t.v2}"/>
        <rect x="37" y="60" width="10" height="5.5" rx="2.75" fill="${t.key}" stroke="none"/>
        <rect x="50" y="60" width="11" height="5.5" rx="2.75" fill="${t.v1}"/>
      </g>
      <g transform="translate(0 -2)">
        <circle cx="70" cy="76" r="14" fill="${t.badge}" stroke="${t.line}" stroke-width="3"/>
        <g fill="none" stroke="${t.arrow}" stroke-width="2.8">${ARROWS}</g>
      </g>
    </g>`;

  // —— 融合风格：App 的构图和配色，按程度加入手绘的线条、涂色或纸感 ——
  const fusion = (t) => (u) => {
    const ROWS = [[39, 13, t.v1], [49.5, 9, t.v2], [60, 11, t.v1]];
    const fill = (mode, color, shape) => mode === "hatch"
      ? `<g fill="url(#${u}h${color.slice(1)})">${shape}</g>`
      : mode === "none" ? "" : `<g fill="${color}">${shape}</g>`;
    const hatchColors = [t.fileMode === "hatch" && t.fileFill, t.badgeMode === "hatch" && t.badge].filter(Boolean);
    const rows = t.marker
      ? `<g stroke-linecap="round" stroke-width="5.5" fill="none">${ROWS.map(([y, w, c]) =>
          `<path d="M39.5 ${y + 2.75} H44.5" stroke="${t.line}"/><path d="M52.5 ${y + 2.75} H${50 + w - 2.5}" stroke="${c}"/>`).join("")}</g>`
      : `<g stroke="${t.line}" stroke-width="1.6">${ROWS.map(([y, w, c]) =>
          `<rect x="37" y="${y}" width="10" height="5.5" rx="2.75" fill="${t.line}" stroke="none"/><rect x="50" y="${y}" width="${w}" height="5.5" rx="2.75" fill="${c}"/>`).join("")}</g>`;
    const wob = t.wobble ? `filter="url(#${u}w)"` : "";
    const wob2 = t.fillWobble ? `filter="url(#${u}w2)"` : "";
    const off = t.offset ? `transform="translate(${t.offset})"` : "";
    return `
    <defs>
      <filter id="${u}w" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".05" numOctaves="2" seed="4"/><feDisplacementMap in="SourceGraphic" scale="${t.wobble || 0}"/></filter>
      <filter id="${u}w2" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".09" numOctaves="2" seed="11"/><feDisplacementMap in="SourceGraphic" scale="${t.fillWobble || 0}"/></filter>
      <filter id="${u}grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="2"/><feColorMatrix values="0 0 0 0 .36  0 0 0 0 .3  0 0 0 0 .24  0 0 0 ${t.grain || 0} 0"/></filter>
      ${hatchColors.map(c => `<pattern id="${u}h${c.slice(1)}" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><line x1="0" y1="0" x2="0" y2="3.2" stroke="${c}" stroke-width="2"/></pattern>`).join("")}
    </defs>
    <rect width="100" height="100" fill="${t.bg}"/>
    ${t.grain ? `<rect width="100" height="100" filter="url(#${u}grain)"/>` : ""}
    <g ${off} ${wob2}>${fill(t.fileMode, t.fileFill, `<path d="${FILE}"/>`)}</g>
    <g ${wob} stroke-linejoin="round" stroke-linecap="round">
      <path d="${FILE}" fill="none" stroke="${t.line}" stroke-width="${t.w}"/>
      <path d="M59 22 V30 Q59 34 63 34 H71" fill="${t.fold}" stroke="${t.line}" stroke-width="${t.w}"/>
      ${rows}
    </g>
    <g transform="translate(0 -2)">
      <circle cx="70" cy="76" r="${14 + t.w / 2 + 1}" fill="${t.bg}"/>
      <g ${off} ${wob2}>${fill(t.badgeMode, t.badge, `<circle cx="70" cy="76" r="14"/>`)}</g>
      <g ${wob} stroke-linejoin="round" stroke-linecap="round">
        <circle cx="70" cy="76" r="14" fill="none" stroke="${t.line}" stroke-width="${t.w}"/>
        <g fill="none" stroke="${t.arrow}" stroke-width="2.8">${ARROWS}</g>
      </g>
    </g>`;
  };

  // —— 手绘风格：铅笔线稿 + 蜡笔斜线涂色 + 纸纹 ——
  // layer：full 完整图标；bg 只有纸底；fg 只有图形（透明底）；mono 只有铅笔线（单色主题图标用）
  const sketch = (t) => (u, layer = "full") => {
    const w = t.weight;
    const pencil = (shapes, sw = w) => `
      <g fill="none" stroke="${t.ink}" stroke-linecap="round" stroke-linejoin="round" filter="url(#${u}r)">
        <g stroke-width="${sw}">${shapes}</g>
        ${t.ghost ? `<g stroke-width="${(sw * 0.4).toFixed(2)}" opacity=".5" transform="translate(-.9 .8)">${shapes}</g>` : ""}
      </g>`;
    const crayon = (color, shapes) => layer === "mono" ? "" :
      `<g fill="url(#${u}h-${color})" transform="translate(1.2 1.4)" filter="url(#${u}r2)">${shapes}</g>`;
    const badgeR = t.rows === 2 ? 14.5 : 13;
    const rows = t.rows === 2
      ? `<path d="M37 43 H45 M50 43 H58 M37 55 H45 M50 55 H55" stroke-width="${w}"/>`
      : `<path d="M37 40 H45 M49 40 H58 M37 50 H45 M49 50 H55 M37 60 H45 M49 60 H54" stroke-width="2.6"/>`;
    return `
    <defs>
      <filter id="${u}r" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".06" numOctaves="2" seed="4"/><feDisplacementMap in="SourceGraphic" scale="2.4"/></filter>
      <filter id="${u}r2" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".09" numOctaves="2" seed="11"/><feDisplacementMap in="SourceGraphic" scale="2.2"/></filter>
      <filter id="${u}grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="2"/><feColorMatrix values="0 0 0 0 ${t.grain}  0 0 0 0 ${t.grain}  0 0 0 0 ${t.grain}  0 0 0 ${t.grainA ?? .1} 0"/></filter>
      <pattern id="${u}h-a" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><line x1="0" y1="0" x2="0" y2="3.2" stroke="${t.fileFill}" stroke-width="2"/></pattern>
      <mask id="${u}m" maskUnits="userSpaceOnUse" x="-50" y="-50" width="200" height="200"><rect x="-50" y="-50" width="200" height="200" fill="#fff"/><circle cx="70" cy="74" r="${badgeR + 2.5}" fill="#000"/></mask>
      <pattern id="${u}h-b" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><line x1="0" y1="0" x2="0" y2="3.2" stroke="${t.badgeFill}" stroke-width="2"/></pattern>
    </defs>
    ${layer === "full" || layer === "bg" ? `<rect x="-50" y="-50" width="200" height="200" fill="${t.bg}"/>
    <rect x="-50" y="-50" width="200" height="200" filter="url(#${u}grain)"/>` : ""}
    ${layer === "bg" ? "" : `
    <g mask="url(#${u}m)">
      ${crayon("a", `<path d="${FILE}"/>`)}
      ${pencil(`<path d="${FILE}"/><path d="M59 22 V34 H71"/>${rows}`)}
    </g>
    <g transform="translate(0 -2)">
      ${crayon("b", `<circle cx="70" cy="76" r="${badgeR}"/>`)}
      ${pencil(`<circle cx="70" cy="76" r="${badgeR}"/>${ARROWS}`, t.rows === 2 ? 3.4 : 2.8)}
    </g>`}`;
  };

  const variants = [
    { id: "app-light", style: "app", name: "浅色", note: "App 浅色主题的配色：纸米底、墨色描边，值用奶油黄和灰绿，同步章用陶橙。",
      draw: app({ bg: "#F2EDE4", card: "#FFFAF2", fold: "#E9E2D5", line: "#1E1B16", key: "#1E1B16", v1: "#F5CF6B", v2: "#BFD2B0", badge: "#E2572B", arrow: "#FFFAF2" }) },
    { id: "app-dark", style: "app", name: "深色", note: "App 深色主题：深煤黑底，奶油色描边，颜色换成深色主题里的对应值。",
      draw: app({ bg: "#17140F", card: "#221E18", fold: "#342E25", line: "#F2EDE4", key: "#F2EDE4", v1: "#E9BD52", v2: "#A3BD92", badge: "#EC6A3C", arrow: "#17140F" }) },
    { id: "app-bold", style: "app", name: "陶橙满底", note: "主色铺满背景，主屏上最醒目；同步章换成墨色。",
      draw: app({ bg: "#E2572B", card: "#FFFAF2", fold: "#F2EDE4", line: "#1E1B16", key: "#1E1B16", v1: "#F5CF6B", v2: "#BFD2B0", badge: "#1E1B16", arrow: "#FFFAF2" }) },
    { id: "mix-crayon", style: "mix", name: "规整线 + 蜡笔色", level: 1, note: "App 的线条和形状完全不变，只把文件和同步章的颜色换成蜡笔斜线涂色。",
      draw: fusion({ bg: "#F2EDE4", line: "#1E1B16", v1: "#F5CF6B", v2: "#BFD2B0", fold: "#E9E2D5", w: 3, fileMode: "hatch", fileFill: "#8DBF92", badgeMode: "hatch", badge: "#E2572B", arrow: "#1E1B16", offset: "1.2 1.4", fillWobble: 1.8, grain: .05 }) },
    { id: "mix-wobble", style: "mix", name: "微抖线 + 实色", level: 2, note: "App 的配色和实色填充不变，线条带一点手抖，底色加淡淡的纸纹。",
      draw: fusion({ bg: "#F2EDE4", line: "#1E1B16", v1: "#F5CF6B", v2: "#BFD2B0", fold: "#E9E2D5", w: 3, fileMode: "solid", fileFill: "#FFFAF2", badgeMode: "solid", badge: "#E2572B", arrow: "#FFFAF2", wobble: 1.5, fillWobble: 1.5, grain: .05 }) },
    { id: "mix-riso", style: "mix", name: "错版印刷", level: 3, note: "像孔版印刷：色块和墨线故意错开一点，颜色还是 App 的灰绿和陶橙。",
      draw: fusion({ bg: "#F2EDE4", line: "#1E1B16", v1: "#F5CF6B", v2: "#BFD2B0", fold: "#E9E2D5", w: 3, fileMode: "solid", fileFill: "#BFD2B0", badgeMode: "solid", badge: "#E2572B", arrow: "#1E1B16", offset: "2.4 2.6", wobble: 1.2, grain: .07 }) },
    { id: "mix-marker", style: "mix", name: "马克笔", level: 4, note: "像用马克笔画的：粗线、圆头，变量行是一笔笔涂出来的色条。",
      draw: fusion({ bg: "#FBF7EE", line: "#1E1B16", v1: "#F5CF6B", v2: "#A9C79B", fold: "#E9E2D5", w: 4, fileMode: "solid", fileFill: "#FFFDF7", badgeMode: "solid", badge: "#E2572B", arrow: "#FFFAF2", wobble: 1.9, fillWobble: 1.9, grain: .06, marker: true }) },
    { id: "sketch-light", style: "sketch", name: "纸面", note: "上一轮的版本：铅笔线稿加重描线，灰绿文件、陶橙同步章。",
      draw: sketch({ bg: "#FBF7EE", ink: "#2A2620", fileFill: "#7FAF84", badgeFill: "#E8693A", grain: ".36", weight: 3.2, ghost: true, rows: 3 }) },
    { id: "sketch-dark", style: "sketch", name: "黑板", note: "深色版本：粉笔线条画在黑板上，适合 iOS 深色图标。",
      draw: sketch({ bg: "#24221E", ink: "#F2EDE4", fileFill: "#8DBF92", badgeFill: "#F08A5D", grain: ".9", grainA: .045, weight: 3.2, ghost: true, rows: 3 }) },
    { id: "sketch-bold", style: "sketch", name: "粗线", note: "为小尺寸简化：线条加粗、去掉重描线，变量只留两行，同步章放大。",
      draw: sketch({ bg: "#FBF7EE", ink: "#2A2620", fileFill: "#7FAF84", badgeFill: "#E8693A", grain: ".36", weight: 4.4, ghost: false, rows: 2 }) },
  ];

  globalThis.HarmoniaEnvSync = {
    variants,
    // opts.layer 见 sketch；opts.viewBox 用于 Android 自适应图标的 108dp 画布；opts.gray 输出 iOS 着色图标用的灰度版
    svg: (id, size, uid = id, opts = {}) => {
      const v = variants.find(x => x.id === id);
      const body = v.draw(uid, opts.layer);
      const gray = opts.gray ? `<filter id="${uid}gray"><feColorMatrix type="saturate" values="0"/></filter>` : "";
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${opts.viewBox || "0 0 100 100"}"${size ? ` width="${size}" height="${size}"` : ""}>${gray}${opts.gray ? `<g filter="url(#${uid}gray)">${body}</g>` : body}</svg>`;
    },
  };
})();
