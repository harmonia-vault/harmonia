// Harmonia 手绘风格图标：铅笔线稿 + 蜡笔斜线涂色 + 纸底。
// 浏览器里挂到 globalThis.HarmoniaSketch；bun build-sketch.mjs 写出 sketch/<id>.svg。
(() => {
  const C = { paper: "#FBF7EE", ink: "#2A2620", yellow: "#F4B93A", orange: "#E8693A", sage: "#7FAF84" };
  const DOLLAR_S = "M57 59.5 C57 56.5 54 55 50 55 C46 55 43 56.8 43 60 C43 63.5 46.5 64.5 50 65.5 C53.5 66.5 57 67.5 57 71 C57 74.2 54 76 50 76 C46 76 43 74.5 43 71.5";
  const DOLLAR = `<path d="${DOLLAR_S}"/><path d="M50 51 V80"/>`;

  const defs = (u) => `
    <defs>
      <filter id="${u}r" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".06" numOctaves="2" seed="4"/><feDisplacementMap in="SourceGraphic" scale="2.4"/></filter>
      <filter id="${u}r2" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".09" numOctaves="2" seed="11"/><feDisplacementMap in="SourceGraphic" scale="2.2"/></filter>
      <filter id="${u}grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="2"/><feColorMatrix values="0 0 0 0 .42  0 0 0 0 .36  0 0 0 0 .28  0 0 0 .09 0"/></filter>
      ${["yellow", "orange", "sage"].map(k => `<pattern id="${u}h-${k}" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><line x1="0" y1="0" x2="0" y2="3.2" stroke="${C[k]}" stroke-width="2"/></pattern>`).join("")}
    </defs>
    <rect width="100" height="100" fill="${C.paper}"/>
    <rect width="100" height="100" filter="url(#${u}grain)"/>`;

  // 蜡笔涂色：比线稿略微错位，像手涂出界
  const crayon = (u, color, shapes) =>
    `<g fill="url(#${u}h-${color})" stroke="none" transform="translate(1.2 1.4)" filter="url(#${u}r2)">${shapes}</g>`;
  // 铅笔线：一条主线 + 一条淡的重描线
  const pencil = (u, shapes, w = 3.2) => `
    <g fill="none" stroke="${C.ink}" stroke-linecap="round" stroke-linejoin="round" filter="url(#${u}r)">
      <g stroke-width="${w}">${shapes}</g>
      <g stroke-width="${(w * 0.4).toFixed(2)}" opacity=".5" transform="translate(-.9 .8)">${shapes}</g>
    </g>`;
  const dots = (u, pts, r = 3) =>
    `<g fill="${C.ink}" filter="url(#${u}r2)">${pts.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="${r}"/>`).join("")}</g>`;

  const subjects = [
    { id: "lock", name: "$ 锁", feature: "变量在客户端加密，服务端只存密文",
      draw: u => crayon(u, "yellow", `<rect x="25" y="45" width="50" height="40" rx="9"/>`)
        + pencil(u, `<path d="M35 45 V35 A15 15 0 0 1 65 35 V45"/><rect x="25" y="45" width="50" height="40" rx="9"/>`)
        + pencil(u, DOLLAR, 3.4) },

    { id: "lock-buddy", name: "小锁精", feature: "加密 + 按设备授权，做成一个有表情的角色",
      draw: u => crayon(u, "orange", `<rect x="24" y="44" width="52" height="42" rx="12"/>`)
        + crayon(u, "yellow", `<path d="M35 44 V34 A15 15 0 0 1 65 34 V44 H58 V34 A8 8 0 0 0 42 34 V44 Z"/>`)
        + pencil(u, `<path d="M35 44 V34 A15 15 0 0 1 65 34 V44"/><rect x="24" y="44" width="52" height="42" rx="12"/><path d="M46.5 70 A3.5 3.5 0 1 1 53.5 70 L52 78 H48 Z"/><path d="M30 66 h5 M65 66 h5" stroke-width="2" opacity=".55"/>`)
        + dots(u, [[39, 60], [61, 60]], 3.2) },

    { id: "phone-key", name: "手机钥匙", feature: "用手机管理环境变量，钥匙在手机上",
      draw: u => crayon(u, "sage", `<rect x="32" y="12" width="36" height="50" rx="8"/>`)
        + crayon(u, "yellow", `<rect x="37" y="18" width="26" height="34" rx="3"/>`)
        + pencil(u, `<rect x="32" y="12" width="36" height="50" rx="8"/><rect x="37" y="18" width="26" height="34" rx="3"/><path d="M50 62 V89 M50 75 H59 M50 84 H56"/><path d="M42 27 H52 M42 35 H56 M42 43 H49" stroke-width="2.6"/>`) },

    { id: "terminal", name: "$_ 终端", feature: "在电脑和运行环境中使用变量",
      draw: u => crayon(u, "yellow", `<rect x="16" y="22" width="68" height="11" rx="5"/>`)
        + `<rect x="47" y="61" width="15" height="6.5" rx="1.5" fill="${C.orange}" filter="url(#${u}r2)"/>`
        + pencil(u, `<rect x="16" y="22" width="68" height="58" rx="8"/><path d="M16 33 H84"/>`)
        + pencil(u, `<g transform="translate(33 57) scale(.9) translate(-50 -65.5)">${DOLLAR}</g>`, 3.4)
        + dots(u, [[23, 27.5], [29.5, 27.5], [36, 27.5]], 1.7) },

    { id: "env-sync", name: ".env 同步", feature: "在授权设备间同步 KEY=VALUE",
      draw: u => crayon(u, "sage", `<path d="M30 14 H56 L70 28 V86 H30 Z"/>`)
        + pencil(u, `<path d="M30 14 H56 L70 28 V86 H30 Z"/><path d="M56 14 V28 H70"/><path d="M37 38 H45 M49 38 H58 M37 48 H45 M49 48 H55 M37 58 H45 M49 58 H54" stroke-width="2.6"/>`)
        + `<circle cx="70" cy="76" r="14.5" fill="${C.paper}"/>`
        + crayon(u, "orange", `<circle cx="70" cy="76" r="13"/>`)
        + pencil(u, `<circle cx="70" cy="76" r="13"/><path d="M63 73 A7.5 7.5 0 0 1 77 72"/><path d="M77.5 67.5 V72.5 H72.5"/><path d="M77 79 A7.5 7.5 0 0 1 63 80"/><path d="M62.5 84.5 V79.5 H67.5"/>`, 2.8) },

    { id: "pair", name: "手机 → 电脑", feature: "手机配对授权，把变量送到电脑",
      draw: u => crayon(u, "yellow", `<rect x="10" y="34" width="24" height="40" rx="5"/>`)
        + crayon(u, "sage", `<rect x="52" y="40" width="38" height="26" rx="3"/>`)
        + pencil(u, `<rect x="10" y="34" width="24" height="40" rx="5"/><path d="M19 68 H25"/><rect x="52" y="40" width="38" height="26" rx="3"/><path d="M46 70 H96 L92 77 H50 Z"/>`)
        + pencil(u, `<path d="M28 28 Q48 6 68 30" stroke-dasharray="4 5"/><path d="M61 29.5 L68.5 31 L69 23.5"/>`, 2.8)
        + pencil(u, `<g transform="translate(48 18) scale(.45) translate(-50 -65.5)">${DOLLAR}</g>`, 2.6) },

    { id: "tree", name: "授权树", feature: "一部手机给多台设备授权：管理 / 读写 / 只读",
      draw: u => crayon(u, "orange", `<circle cx="22" cy="76" r="10"/>`)
        + crayon(u, "yellow", `<circle cx="50" cy="76" r="10"/>`)
        + crayon(u, "sage", `<circle cx="78" cy="76" r="10"/>`)
        + pencil(u, `<rect x="39" y="12" width="22" height="32" rx="5"/><path d="M47 38 H53"/><path d="M50 44 V55 M22 66 V55 H78 V66 M50 55 V66"/><circle cx="22" cy="76" r="10"/><circle cx="50" cy="76" r="10"/><circle cx="78" cy="76" r="10"/>`) },

    { id: "squirrel", name: "松鼠", feature: "把变量（橡果）藏好，按需带到各台设备",
      draw: u => crayon(u, "orange", `<path d="M60 98 C50 72 52 42 66 27 C76 17 95 21 92 37 C90 46 80 47 77 40 C70 52 68 74 76 98 Z"/>`)
        + crayon(u, "yellow", `<ellipse cx="36" cy="89" rx="7.5" ry="8.5"/>`)
        + crayon(u, "orange", `<path d="M26.5 83 Q36 72 45.5 83 Z"/>`)
        + pencil(u, `<path d="M60 98 C50 72 52 42 66 27 C76 17 95 21 92 37 C90 46 80 47 77 40 C70 52 68 74 76 98"/><path d="M10 100 C12 86 20 78 28 76 M44 76 C50 78 55 84 57 92"/><ellipse cx="36" cy="57" rx="22" ry="18.5"/><path d="M20 45 C14 34 18 26 23 27 C27 28 29 36 28 41 M44 41 C43 34 46 27 50 27 C55 27 57 35 52 45"/><ellipse cx="36" cy="89" rx="7.5" ry="8.5"/><path d="M26.5 83 Q36 72 45.5 83 Z"/><path d="M36 76.5 V72.5"/><path d="M31.5 63 Q36 67 40.5 63" stroke-width="2.4"/>`)
        + dots(u, [[28, 56], [44, 56]], 3) },
  ];

  globalThis.HarmoniaSketch = {
    subjects,
    svg: (id, size, uid = id) => {
      const s = subjects.find(x => x.id === id);
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"${size ? ` width="${size}" height="${size}"` : ""}>${defs(uid)}${s.draw(uid)}</svg>`;
    },
  };
})();
