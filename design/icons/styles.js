// Harmonia 风格样板：同一个主题（钥匙孔是 $ 的锁 = 加密的环境变量），九种完全不同的画法。
// 浏览器里挂到 globalThis.HarmoniaStyles；bun build-styles.mjs 写出 styles/*.svg。
(() => {
  const wrap = (body, size) =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"${size ? ` width="${size}" height="${size}"` : ""}>${body}</svg>`;
  const DOLLAR_S = "M57 59.5 C57 56.5 54 55 50 55 C46 55 43 56.8 43 60 C43 63.5 46.5 64.5 50 65.5 C53.5 66.5 57 67.5 57 71 C57 74.2 54 76 50 76 C46 76 43 74.5 43 71.5";

  // 1 像素：16×16 网格
  const pixel = (u) => {
    const P = {
      b: "#2E3A59", s: "#C7CEDB", S: "#8E98AD", y: "#F5CF6B", Y: "#D9A93A", h: "#FFE7A3", k: "#1E1B16",
    };
    const rows = [
      "bbbbbbbbbbbbbbbb",
      "bbbbbssssssbbbbb",
      "bbbbsSbbbbSsbbbb",
      "bbbssbbbbbbssbbb",
      "bbbsSbbbbbbsSbbb",
      "bbbsSbbbbbbsSbbb",
      "bbhhhhhhhhhhhhbb",
      ...Array(7).fill("bbhyyyyyyyyyyYbb"),
      "bbYYYYYYYYYYYYbb",
      "bbbbbbbbbbbbbbbb",
    ].map(r => [...r]);
    ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."].forEach((g, dy) =>
      [...g].forEach((c, dx) => { if (c === "#") rows[7 + dy][5 + dx] = "k"; }));
    let r = "";
    rows.forEach((row, y) => row.forEach((c, x) => {
      r += `<rect x="${x * 6.25}" y="${y * 6.25}" width="6.3" height="6.3" fill="${P[c]}"/>`;
    }));
    return `<g shape-rendering="crispEdges">${r}</g>`;
  };

  // 2 线描：系统图标式单线，渐变底
  const line = (u) => `
    <defs><linearGradient id="${u}g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3FD0A8"/><stop offset="1" stop-color="#1E9E86"/></linearGradient></defs>
    <rect width="100" height="100" fill="url(#${u}g)"/>
    <g fill="none" stroke="#fff" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round">
      <path d="M35 45 V35 A15 15 0 0 1 65 35 V45"/>
      <rect x="25" y="45" width="50" height="40" rx="10"/>
      <path d="${DOLLAR_S}" stroke-width="4"/><path d="M50 51 V80" stroke-width="4"/>
    </g>`;

  // 3 拟物：黄铜挂锁放在皮革上
  const skeuo = (u) => `
    <defs>
      <radialGradient id="${u}bg" cx=".35" cy=".3" r=".9"><stop offset="0" stop-color="#6B4429"/><stop offset="1" stop-color="#2A180C"/></radialGradient>
      <linearGradient id="${u}br" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FBE3A0"/><stop offset=".45" stop-color="#D9A53F"/><stop offset="1" stop-color="#8A5F12"/></linearGradient>
      <linearGradient id="${u}st" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#8C8F96"/><stop offset=".3" stop-color="#F4F5F7"/><stop offset=".55" stop-color="#A9ADB5"/><stop offset=".8" stop-color="#E6E8EC"/><stop offset="1" stop-color="#7B7F87"/></linearGradient>
      <linearGradient id="${u}hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
      <filter id="${u}sh" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="3" stdDeviation="3" flood-color="#000" flood-opacity=".55"/></filter>
    </defs>
    <rect width="100" height="100" fill="url(#${u}bg)"/>
    <path d="M34 47 V34 A16 16 0 0 1 66 34 V47" fill="none" stroke="url(#${u}st)" stroke-width="9" stroke-linecap="round" filter="url(#${u}sh)"/>
    <rect x="23" y="44" width="54" height="44" rx="9" fill="url(#${u}br)" filter="url(#${u}sh)"/>
    <rect x="25.5" y="46" width="49" height="16" rx="7" fill="url(#${u}hl)"/>
    <rect x="23" y="44" width="54" height="44" rx="9" fill="none" stroke="#6B4A0E" stroke-opacity=".6" stroke-width="1"/>
    <g fill="none" stroke-linecap="round">
      <path d="${DOLLAR_S}" stroke="#FCE7A8" stroke-width="4.4" transform="translate(0 .9)"/><path d="M50 52 V80" stroke="#FCE7A8" stroke-width="4" transform="translate(0 .9)"/>
      <path d="${DOLLAR_S}" stroke="#4A320A" stroke-width="4.4"/><path d="M50 52 V80" stroke="#4A320A" stroke-width="4"/>
    </g>`;

  // 4 等距：等距视角的小方块锁
  const iso = (u) => {
    const cx = 41.3, cy = 52;
    const p = (x, y, z) => [cx + (x - y) * 0.866, cy + (x + y) * 0.5 - z];
    const poly = (pts, fill) => `<polygon points="${pts.map(q => p(...q).map(n => n.toFixed(2)).join(",")).join(" ")}" fill="${fill}"/>`;
    const W = 40, D = 20, H = 32;
    let arc = [];
    for (let i = 0; i <= 24; i++) {
      const t = Math.PI * i / 24;
      arc.push(p(10 + 10 * (1 - Math.cos(t)), D / 2, H + 2 + 15 * Math.sin(t)));
    }
    const legL = p(10, D / 2, H - 1), legR = p(30, D / 2, H - 1);
    const arcPath = `M${legL.join(" ")} L${arc.map(a => a.map(n => n.toFixed(2)).join(" ")).join(" L")} L${legR.join(" ")}`;
    const [fx, fy] = p(W / 2, D, H / 2);
    return `
    <rect width="100" height="100" fill="#DCE6E0"/>
    <polygon points="${[p(0, D, 0), p(W, D, 0), p(W, D + 3, -3), p(0, D + 3, -3)].map(q => q.join(",")).join(" ")}" fill="#B9C9C0"/>
    <path d="${arcPath}" fill="none" stroke="#3D5A4A" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round"/>
    ${poly([[0, 0, H], [W, 0, H], [W, D, H], [0, D, H]], "#FFDD85")}
    ${poly([[0, D, 0], [W, D, 0], [W, D, H], [0, D, H]], "#F2B941")}
    ${poly([[W, 0, 0], [W, D, 0], [W, D, H], [W, 0, H]], "#C98A20")}
    <text x="0" y="0" transform="matrix(.866 .5 0 1 ${fx.toFixed(2)} ${(fy + 9).toFixed(2)})" text-anchor="middle" font-family="'JetBrains Mono', Menlo, monospace" font-weight="800" font-size="26" fill="#3D2A08">$</text>`;
  };

  // 5 霓虹：暗底发光线
  const neon = (u) => `
    <defs><filter id="${u}gl" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="2.4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
    <rect width="100" height="100" fill="#0B0F1A"/>
    <g fill="none" stroke-linecap="round" stroke-linejoin="round" filter="url(#${u}gl)">
      <g stroke="#3EF0FF" stroke-width="3.6"><path d="M35 45 V35 A15 15 0 0 1 65 35 V45"/><rect x="25" y="45" width="50" height="40" rx="10"/></g>
      <g stroke="#FF4FD8" stroke-width="3.4"><path d="${DOLLAR_S}"/><path d="M50 51 V80"/></g>
    </g>`;

  // 6 包豪斯：纯几何与原色
  const bauhaus = (u) => `
    <rect width="100" height="100" fill="#EFE5D0"/>
    <path d="M28 50 A22 22 0 0 1 72 50 L60 50 A10 10 0 0 0 40 50 Z" fill="#D93A2B"/>
    <rect x="18" y="50" width="64" height="38" fill="#1F4E9C"/>
    <circle cx="50" cy="63" r="7" fill="#F2B705"/>
    <path d="M45 66 H55 L53 80 H47 Z" fill="#F2B705"/>
    <rect x="18" y="50" width="18" height="18" fill="#111"/>`;

  // 7 剪纸：几层纸叠在一起，带投影
  const paper = (u) => `
    <defs><filter id="${u}ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="1.6" stdDeviation="1.4" flood-color="#3B2A12" flood-opacity=".35"/></filter></defs>
    <rect width="100" height="100" fill="#E9D8B4"/>
    <circle cx="50" cy="52" r="38" fill="#2A9D8F" filter="url(#${u}ds)"/>
    <path d="M36 50 V37 A14 14 0 0 1 64 37 V50 H57 V38 A7 7 0 0 0 43 38 V50 Z" fill="#F4F1DE" filter="url(#${u}ds)"/>
    <rect x="26" y="47" width="48" height="36" rx="7" fill="#E76F51" filter="url(#${u}ds)"/>
    <rect x="30" y="51" width="40" height="28" rx="5" fill="#F4A261" filter="url(#${u}ds)"/>
    <g fill="none" stroke="#264653" stroke-linecap="round" filter="url(#${u}ds)" transform="translate(0 -0.5) scale(1 .92) translate(0 5.6)">
      <path d="${DOLLAR_S}" stroke-width="4.2"/><path d="M50 52 V79" stroke-width="3.8"/>
    </g>`;

  // 8 黏土 3D：圆鼓鼓的软体积
  const clay = (u) => `
    <defs>
      <radialGradient id="${u}b" cx=".32" cy=".28" r=".85"><stop offset="0" stop-color="#FFB08A"/><stop offset=".55" stop-color="#EE6A3E"/><stop offset="1" stop-color="#B9401C"/></radialGradient>
      <linearGradient id="${u}s" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#5C7CFA"/><stop offset=".35" stop-color="#A8B8FF"/><stop offset="1" stop-color="#3D5BD9"/></linearGradient>
      <radialGradient id="${u}bg" cx=".5" cy=".4" r=".8"><stop offset="0" stop-color="#FFF4EA"/><stop offset="1" stop-color="#F8DCC8"/></radialGradient>
      <filter id="${u}sh" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="5" stdDeviation="4" flood-color="#A8441F" flood-opacity=".35"/></filter>
      <filter id="${u}in" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="1.2" stdDeviation=".8" flood-color="#7A2A10" flood-opacity=".5"/></filter>
    </defs>
    <rect width="100" height="100" fill="url(#${u}bg)"/>
    <path d="M35 47 V35 A15 15 0 0 1 65 35 V47" fill="none" stroke="url(#${u}s)" stroke-width="10" stroke-linecap="round" filter="url(#${u}sh)"/>
    <rect x="22" y="43" width="56" height="45" rx="16" fill="url(#${u}b)" filter="url(#${u}sh)"/>
    <g fill="none" stroke="#FFF6EE" stroke-linecap="round" filter="url(#${u}in)">
      <path d="${DOLLAR_S}" stroke-width="5"/><path d="M50 52 V79" stroke-width="4.6"/>
    </g>`;

  // 9 手绘：铅笔线稿 + 蜡笔涂色
  const sketch = (u) => `
    <defs>
      <filter id="${u}r" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".06" numOctaves="2" seed="4"/><feDisplacementMap in="SourceGraphic" scale="2.6"/></filter>
      <filter id="${u}r2" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency=".09" numOctaves="2" seed="9"/><feDisplacementMap in="SourceGraphic" scale="2"/></filter>
      <pattern id="${u}h" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><rect width="3.2" height="3.2" fill="none"/><line x1="0" y1="0" x2="0" y2="3.2" stroke="#F4B93A" stroke-width="1.9"/></pattern>
    </defs>
    <rect width="100" height="100" fill="#FBF7EE"/>
    <rect x="26" y="47" width="50" height="40" rx="9" fill="url(#${u}h)" filter="url(#${u}r2)"/>
    <g fill="none" stroke="#2A2620" stroke-linecap="round" stroke-linejoin="round" filter="url(#${u}r)">
      <path d="M35 45 V35 A15 15 0 0 1 65 35 V45" stroke-width="3.4"/>
      <path d="M36 44 V35.5 A14 14 0 0 1 64.5 35 V44" stroke-width="1.4" opacity=".6"/>
      <rect x="25" y="45" width="50" height="40" rx="9" stroke-width="3.2"/>
      <rect x="24" y="46.5" width="51.5" height="39" rx="9" stroke-width="1.3" opacity=".55"/>
      <path d="${DOLLAR_S}" stroke-width="3.6"/><path d="M50 51 V80" stroke-width="3.2"/>
    </g>`;

  const styles = [
    { id: "pixel", name: "像素", feel: "8-bit 游戏感，复古，有梗", build: pixel },
    { id: "line", name: "系统线描", feel: "像 iOS 设置里的图标，干净、克制、工具感强", build: line },
    { id: "skeuo", name: "拟物", feel: "老 iOS 的质感：黄铜锁、皮革底，有分量", build: skeuo },
    { id: "iso", name: "等距 3D", feel: "积木式小场景，偏技术与架构感", build: iso },
    { id: "neon", name: "霓虹", feel: "暗色终端里的发光线，偏黑客、夜间", build: neon },
    { id: "bauhaus", name: "包豪斯", feel: "纯几何加红黄蓝原色，海报感、设计感", build: bauhaus },
    { id: "paper", name: "剪纸", feel: "几层彩纸叠出来，温暖、手作、有层次", build: paper },
    { id: "clay", name: "黏土 3D", feel: "圆鼓鼓的软体积，亲和、现代、像玩具", build: clay },
    { id: "sketch", name: "手绘", feel: "铅笔线稿加蜡笔涂色，随性、个人化", build: sketch },
  ];

  globalThis.HarmoniaStyles = {
    styles,
    svg: (id, size, uid = id) => wrap(styles.find(s => s.id === id).build(uid), size),
  };
})();
