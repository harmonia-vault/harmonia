// 实例首页：在浏览器里直接打开服务器地址时看到的页面。
// 只带一段内嵌脚本（复制按钮，内容安全策略按哈希放行），不加载任何外部资源，
// 也不透露这台服务器的配置（是否开放注册、有多少账号）。
import { encode } from "uqr";

const REPO = "https://github.com/harmonia-vault/harmonia";
const FEED = `${REPO}/releases/download/update-feed`;

// —— 手绘图形：墨线画两遍（一粗一细，略微错开），斜线涂色稍微偏出轮廓。取自 design/icons/envsync.js 的手绘版。
// 颜色同时写在属性和 class 上：图标单独用作网站图标时取属性里的浅色，页面里由 CSS 按深浅色覆盖。
const strokes = (shapes: string, width: number) =>
  `<g fill="none" stroke="#2A2620" class="k" stroke-linecap="round" stroke-linejoin="round" filter="url(#sk1)">` +
  `<g stroke-width="${width}">${shapes}</g>` +
  `<g stroke-width="${width * 0.4}" opacity=".5" transform="translate(-.9 .8)">${shapes}</g></g>`;
const hatch = (shape: string, pattern: string) =>
  `<g fill="url(#${pattern})" transform="translate(1.2 1.4)" filter="url(#sk2)">${shape}</g>`;
const wobble = (id: string, frequency: string, seed: number, scale: string) =>
  `<filter id="${id}" x="-10%" y="-10%" width="120%" height="120%">` +
  `<feTurbulence type="fractalNoise" baseFrequency="${frequency}" numOctaves="2" seed="${seed}"/>` +
  `<feDisplacementMap in="SourceGraphic" scale="${scale}"/></filter>`;
const stripes = (id: string, color: string, cls: string) =>
  `<pattern id="${id}" width="3.2" height="3.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)">` +
  `<line x1="0" y1="0" x2="0" y2="3.2" stroke="${color}" class="${cls}" stroke-width="2"/></pattern>`;

const DEFS =
  `<defs>${wobble("sk1", ".06", 4, "2.4")}${wobble("sk2", ".09", 11, "2.2")}` +
  `${stripes("hg", "#7FAF84", "g")}${stripes("ho", "#E8693A", "o")}${stripes("hy", "#E9BD52", "y")}` +
  `<mask id="im" maskUnits="userSpaceOnUse" x="-50" y="-50" width="200" height="200">` +
  `<rect x="-50" y="-50" width="200" height="200" fill="#fff"/><circle cx="70" cy="74" r="15.5" fill="#000"/></mask></defs>`;

const FILE = `<path d="M29 22 H59 L71 34 V78 H29 Z"/>`;
const FILE_LINES = `<path d="M59 22 V34 H71"/><path d="M37 40 H45 M49 40 H58 M37 50 H45 M49 50 H55 M37 60 H45 M49 60 H54" stroke-width="2.6"/>`;
const BADGE = `<circle cx="70" cy="76" r="13"/>`;
const ARROWS = `<path d="M63 73 A7.5 7.5 0 0 1 77 72"/><path d="M77.5 67.5 V72.5 H72.5"/><path d="M77 79 A7.5 7.5 0 0 1 63 80"/><path d="M62.5 84.5 V79.5 H67.5"/>`;

/** Harmonia 图标；其余图形借用它里面定义的线条和涂色。 */
const ICON =
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" class="mark" aria-hidden="true">${DEFS}` +
  `<rect width="100" height="100" fill="#FBF7EE" class="bg"/>` +
  `<g mask="url(#im)">${hatch(FILE, "hg")}${strokes(FILE + FILE_LINES, 3.2)}</g>` +
  `<g transform="translate(0 -2)">${hatch(BADGE, "ho")}${strokes(BADGE + ARROWS, 2.8)}</g></svg>`;

const glyph = (fill: string, pattern: string, lines: string) =>
  `<svg viewBox="0 0 100 100" class="glyph" aria-hidden="true">${hatch(fill, pattern)}${strokes(fill + lines, 3.2)}</svg>`;

const PHONE = glyph(
  `<path d="M36 12 H64 Q70 12 70 18 V82 Q70 88 64 88 H36 Q30 88 30 82 V18 Q30 12 36 12 Z"/>`,
  "hg",
  `<path d="M45 21 H55"/><path d="M38 38 H45 M49 38 H62 M38 49 H45 M49 49 H58 M38 60 H45 M49 60 H60" stroke-width="2.6"/>`,
);
const SERVER = glyph(
  `<path d="M16 22 H84 V46 H16 Z"/><path d="M16 54 H84 V78 H16 Z"/>`,
  "ho",
  `<path d="M27 34 H29 M37 34 H39 M56 34 H73 M27 66 H29 M37 66 H39 M56 66 H73"/>`,
);
const LAPTOP = glyph(
  `<path d="M24 20 H76 V60 H24 Z"/>`,
  "hy",
  `<path d="M12 68 H88 L82 78 H18 Z"/><path d="M34 33 L42 40 L34 47 M48 48 H60" stroke-width="2.6"/>`,
);

// 配色与 App 相同（app/lib/ui/theme.dart）。
const STYLE = `
:root{--paper:#F2EDE4;--card:#FFFAF2;--ink:#1E1B16;--mute:#6E675C;--line:#DDD4C4;--accent:#E2572B;--on-accent:#FFFAF2;--ok:#2F7D4F;
--yellow:#F5CF6B;--term:#1E1B16;--term-edge:#1E1B16;--ic-bg:#FBF7EE;--ic-ink:#2A2620;--ic-g:#7FAF84;--ic-o:#E8693A;--ic-y:#E9BD52}
@media(prefers-color-scheme:dark){:root{--paper:#17140F;--card:#221E18;--ink:#F2EDE4;--mute:#A69D8D;--line:#342E25;--accent:#EC6A3C;
--on-accent:#17140F;--ok:#79C792;--yellow:#E9BD52;--term:#0E0C09;--term-edge:#342E25;--ic-bg:#24221E;--ic-ink:#F2EDE4;--ic-g:#8DBF92;--ic-o:#F08A5D}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.65 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei","Segoe UI",sans-serif}
code{font-family:ui-monospace,"SF Mono",Menlo,Consolas,"Courier New",monospace}
a{color:inherit}
a:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:4px}
.k{stroke:var(--ic-ink)}.bg{fill:var(--ic-bg)}.g{stroke:var(--ic-g)}.o{stroke:var(--ic-o)}.y{stroke:var(--ic-y)}
.wrap{max-width:720px;margin:0 auto;padding:20px 20px 48px}
.top{display:flex;align-items:center;gap:12px}
.mark{display:block;width:44px;height:44px;border:1.5px solid var(--ink);border-radius:12px}
.name{font-size:18px;font-weight:700}
.name span{margin-left:6px;font-size:14px;font-weight:400;color:var(--mute)}
.status{display:inline-flex;align-items:center;gap:8px;margin-left:auto;padding:4px 12px;border:1.5px solid var(--line);border-radius:999px;background:var(--card);font-size:13px}
.status i{width:8px;height:8px;border-radius:50%;background:var(--ok);animation:beat 2.4s ease-out infinite}
@keyframes beat{0%{box-shadow:0 0 0 0 var(--ok)}70%,100%{box-shadow:0 0 0 7px transparent}}
@media(prefers-reduced-motion:reduce){.status i{animation:none}}
h1{margin:56px 0 16px;font-size:clamp(26px,7.4vw,44px);line-height:1.2;font-weight:800;text-wrap:balance}
h1 em{font-style:normal;text-decoration:underline var(--yellow);text-decoration-thickness:.16em;text-underline-offset:.14em;text-decoration-skip-ink:none}
.lead{margin:0;max-width:34em;font-size:17px;color:var(--mute)}
.addr{display:flex;align-items:center;gap:20px;margin-top:32px;padding:18px 20px;border:1.5px solid var(--ink);border-radius:18px;background:var(--card);box-shadow:4px 4px 0 var(--yellow)}
.ai{position:relative;margin:0 0 20px;padding:14px 16px;border:1.5px solid var(--ink);border-radius:14px;background:var(--card);box-shadow:4px 4px 0 var(--accent)}
.ai span{display:block;font-size:12px;color:var(--mute)}
.ai .prompt{max-height:9.4em;max-height:calc(5lh + 20px);margin:6px 0 0;padding:10px 12px;overflow-y:auto;overscroll-behavior:contain;scrollbar-width:thin;scrollbar-color:var(--mute) transparent;border:1.5px dashed var(--ink);border-radius:10px;color:var(--ink);font-size:15px;line-height:1.6;overflow-wrap:anywhere;-webkit-user-select:all;user-select:all}
.ai .prompt::-webkit-scrollbar{width:6px}
.ai .prompt::-webkit-scrollbar-thumb{border-radius:3px;background:var(--mute)}
.copy{position:absolute;top:10px;right:12px;padding:1px 10px;border:1.5px solid currentColor;border-radius:8px;background:transparent;color:inherit;font:inherit;font-size:12px;line-height:20px;cursor:pointer}
.copy:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.addr div{position:relative;flex:1;min-width:0}
.qr{flex:none;width:136px;height:136px;border-radius:10px}
.addr span{display:block;font-size:13px;letter-spacing:.08em;color:var(--mute)}
.addr .copy{top:0;right:0}
.addr code{display:block;margin:2px 0 8px;font-size:clamp(17px,4.6vw,22px);font-weight:600;line-height:1.4;word-break:break-all;-webkit-user-select:all;user-select:all}
.addr p{margin:0;font-size:14px;color:var(--mute)}
h2{margin:64px 0 24px;font-size:22px}
h3{margin:0 0 4px;font-size:17px}
p{margin:0 0 12px;color:var(--mute)}
.steps{margin:0;padding:0;list-style:none;counter-reset:step}
.steps li{position:relative;min-width:0;padding:3px 0 28px 52px;counter-increment:step}
.steps li:last-child{padding-bottom:0}
.steps li::before{content:counter(step);position:absolute;left:0;top:0;display:grid;place-items:center;width:34px;height:34px;border:1.5px solid var(--ink);border-radius:50%;background:var(--yellow);color:#1E1B16;font-weight:700;line-height:1}
.steps li:not(:last-child)::after{content:"";position:absolute;left:16px;top:42px;bottom:8px;border-left:2px dashed var(--line)}
.btn{display:inline-block;margin-right:16px;padding:8px 18px;border:1.5px solid var(--ink);border-radius:12px;background:var(--accent);color:var(--on-accent);font-weight:600;text-decoration:none}
.term{position:relative;margin:0 0 12px;padding:12px 16px;border:1.5px solid var(--term-edge);border-radius:14px;background:var(--term);color:#F2EDE4}
.term span{display:block;font-size:12px;color:#A69D8D}
.term code{display:block;padding:2px 0;font-size:13.5px;line-height:1.6;word-break:break-all;-webkit-user-select:all;user-select:all}
.or{margin-top:20px;margin-bottom:8px}
.addr span,.term span,.ai span{padding-right:64px;min-height:26px}
.flow{display:grid;grid-template-columns:repeat(3,1fr)}
.node{position:relative;padding:0 10px;text-align:center}
.node+.node::before{content:"";position:absolute;top:42px;left:calc(-50% + 54px);width:calc(100% - 108px);border-top:2px dashed var(--ink);opacity:.4}
.glyph{width:84px;height:84px}
.node h3{margin-top:6px}
.node p{margin:0;font-size:14px;text-wrap:balance}
footer{margin-top:64px;padding-top:20px;border-top:1.5px solid var(--line);font-size:13px;color:var(--mute)}
footer p{margin:0 0 6px}
footer a{margin-right:16px}
@media(max-width:600px){
h1{margin-top:40px}
.addr{flex-direction:column;align-items:flex-start;gap:14px}
.addr div{align-self:stretch}
.qr{width:152px;height:152px}
h2{margin-top:48px}
.flow{grid-template-columns:1fr}
.node{display:grid;grid-template-columns:60px 1fr;gap:14px;padding:0 0 24px;text-align:left}
.node:last-child{padding-bottom:0}
.node+.node::before{top:-22px;left:29px;width:0;height:18px;border-top:0;border-left:2px dashed var(--ink)}
.glyph{width:60px;height:60px}
.node h3{margin-top:4px}
.node p{text-wrap:wrap}
}`;

/** 服务器地址的二维码，App 的“连接服务器”页扫它来填地址。始终深色画在浅底上，四周留 3 格空白，深色模式下也能扫。 */
function qrCode(text: string): string {
  const { data, size } = encode(text, { ecc: "M", border: 0 });
  let d = "";
  data.forEach((row, y) => {
    for (let x = 0; x < size; x++) {
      if (!row[x]) continue;
      let end = x;
      while (end + 1 < size && row[end + 1]) end++;
      d += `M${x} ${y}h${end - x + 1}v1h-${end - x + 1}z`;
      x = end;
    }
  });
  return `<svg viewBox="-3 -3 ${size + 6} ${size + 6}" class="qr" role="img" aria-label="服务器地址的二维码" shape-rendering="crispEdges">` +
    `<rect x="-3" y="-3" width="${size + 6}" height="${size + 6}" fill="#FFFAF2"/><path fill="#1E1B16" d="${d}"/></svg>`;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** 复制给 AI 助手的提示词，各个系统通用：先介绍 Harmonia，再让它安装命令行、读取 harmonia skill 的说明、接入这台服务器。用第三人称称呼用户，地址都用这台服务器的地址。 */
function aiPrompt(origin: string): string {
  return escapeHtml(
    `Harmonia（和弦，${origin}）是用户部署的环境变量同步服务，开源、自托管：用户在手机 App 上管理 API Key 等环境变量，端到端加密后同步到用户授权的电脑，你可以用它的命令行取用这些变量，不需要用户把 Key 贴进对话。` +
      `请在这台电脑上安装 Harmonia 命令行：macOS、Linux 运行 curl -fsSL ${FEED}/install.sh | HARMONIA_YES=0 sh；` +
      `Windows 在 PowerShell 中运行 $env:HARMONIA_YES = '0'; irm ${FEED}/install.ps1 | iex。` +
      `装好后运行 harmonia skill，按输出的说明接入服务器 ${origin}（邮箱和配对码向用户询问），并询问用户是否开启 Shell 集成和后台服务。`,
  );
}

// 复制按钮：给每个带 data-copy 的元素加一个按钮，复制它的文字。没有脚本时文字仍可点一下整段选中。
// 剪贴板接口只在 HTTPS（和 localhost）下可用，其他情况选中文字后用 execCommand 复制。
const COPY_SCRIPT = `document.querySelectorAll("[data-copy]").forEach(function(el){
var b=document.createElement("button");b.type="button";b.className="copy";b.textContent="复制";
function show(t){b.textContent=t;setTimeout(function(){b.textContent="复制"},1600)}
function fallback(){var r=document.createRange();r.selectNodeContents(el);var s=getSelection();s.removeAllRanges();s.addRange(r);
try{show(document.execCommand("copy")?"已复制":"请手动复制")}catch(e){show("请手动复制")}}
b.addEventListener("click",function(){var t=el.textContent;
if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t).then(function(){show("已复制")},fallback)}else{fallback()}});
el.parentNode.appendChild(b)})`;

let scriptHash: Promise<string> | undefined;
/** 复制脚本的 SHA-256（base64），写进内容安全策略，只放行这一段脚本。 */
function copyScriptHash(): Promise<string> {
  scriptHash ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(COPY_SCRIPT)).then((d) => btoa(String.fromCharCode(...new Uint8Array(d))));
  return scriptHash;
}

function page(origin: string): string {
  const address = escapeHtml(origin);
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<meta name="description" content="这是一台 Harmonia 服务器。Harmonia 是自托管的环境变量同步工具。">
<title>Harmonia 服务器</title>
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(ICON)}">
<style>${STYLE}</style>
</head>
<body>
<div class="wrap">
<header class="top">
${ICON}
<div class="name">Harmonia<span>和弦</span></div>
<div class="status"><i></i>运行中</div>
</header>
<main>
<h1>这是一台 <em>Harmonia</em> 服务器</h1>
<p class="lead">Harmonia 是一个自托管的环境变量同步工具：在手机上集中管理 API Key 等环境变量，授权给自己的电脑、服务器和 AI Agent 环境使用。</p>
<div class="addr">
<div>
<span>服务器地址</span>
<code data-copy>${address}</code>
<p>在 App 的“连接服务器”页扫这个二维码，或者手动填这个地址，就能连接到这台服务器。</p>
</div>
${qrCode(origin)}
</div>

<h2>开始使用</h2>
<ol class="steps">
<li>
<h3>安装 App</h3>
<p>Android 下载 APK 直接安装；iPhone 下载 IPA，自己签名后安装。</p>
<a class="btn" href="${REPO}/releases/latest">下载 App</a><a href="${REPO}#在-iphone-上安装">iPhone 安装说明</a>
</li>
<li>
<h3>注册或接入</h3>
<p>打开 App，扫描上面的二维码，或者手动填写服务器地址，然后输入邮箱：新邮箱会注册账号，已有账号就接入这台手机。</p>
</li>
<li>
<h3>接入电脑</h3>
<p>在电脑上安装命令行，再接入这台服务器。</p>
<div class="ai">
<span>让 AI 助手安装</span>
<p class="prompt" data-copy>${aiPrompt(origin)}</p>
</div>
<p class="or">或者自己安装，用 App 扫终端里的二维码批准：</p>
<div class="term"><span>macOS、Linux</span><code data-copy>curl -fsSL ${FEED}/install.sh | sh</code></div>
<div class="term"><span>Windows（PowerShell）</span><code data-copy>irm ${FEED}/install.ps1 | iex</code></div>
<div class="term"><span>安装后接入</span><code data-copy>harmonia login ${address}</code></div>
</li>
</ol>

<h2>它是怎么工作的</h2>
<div class="flow">
<div class="node">${PHONE}<div><h3>手机负责授权</h3><p>新电脑要扫码配对，由手机决定它能用哪些环境、用多久，随时可以撤销。</p></div></div>
<div class="node">${SERVER}<div><h3>服务器只存密文</h3><p>变量在手机或电脑上加密后才上传，这台服务器读不到内容。</p></div></div>
<div class="node">${LAPTOP}<div><h3>电脑自动同步</h3><p>手机上改一次，几秒内同步到在线的电脑，在终端里直接使用。</p></div></div>
</div>
</main>
<footer>
<p>Harmonia 是开源软件（MIT）。这台服务器由部署它的人自行运营，与 Harmonia 项目方无关。</p>
<a href="${REPO}">项目主页</a><a href="${REPO}-worker">自己部署一台</a>
</footer>
</div>
<script>${COPY_SCRIPT}</script>
</body>
</html>
`;
}

/** origin 是访问者用的地址（协议加主机名），页面上原样显示，供填进 App 和命令行。 */
export async function homePage(origin: string): Promise<Response> {
  const hash = await copyScriptHash();
  return new Response(page(origin), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy": `default-src 'none'; script-src 'sha256-${hash}'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}
