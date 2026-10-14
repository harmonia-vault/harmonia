// 界面图标：统一的 24 格线条图标（线宽 1.75，圆头），用 DOM 接口画出，颜色跟随文字。
const NS = 'http://www.w3.org/2000/svg';
const P = (d) => ['path', { d }];
const C = (cx, cy, r) => ['circle', { cx, cy, r }];
const R = (x, y, width, height, rx) => ['rect', { x, y, width, height, rx }];

const SHAPES = {
  close: [P('M6 6l12 12M18 6L6 18')],
  plus: [P('M12 5v14M5 12h14')],
  lock: [R(5, 11, 14, 9, 2), P('M8 11V8a4 4 0 0 1 8 0v3')],
  settings: [P('M4 7h9M19 7h1M4 17h1M11 17h9'), C(16, 7, 2.5), C(8, 17, 2.5)],
  eye: [P('M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z'), C(12, 12, 2.75)],
  eyeOff: [P('M9.5 5.9A8.6 8.6 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-2.6 3.4M14.6 14.7a3.7 3.7 0 0 1-5.3-5.3M6.3 7.3A15.6 15.6 0 0 0 2.5 12S6 18.5 12 18.5a8.7 8.7 0 0 0 4.2-1.1M4 4l16 16')],
  copy: [R(9, 9, 11, 11, 2), P('M5 15V6a2 2 0 0 1 2-2h8')],
  edit: [P('M4 20l1-4L16.5 4.5a2.12 2.12 0 0 1 3 3L8 19l-4 1zM14.5 6.5l3 3')],
  trash: [P('M4 7h16M9 7V4h6v3M6.5 7l.9 13h9.2l.9-13M10 11v5M14 11v5')],
  upload: [P('M12 15V4M7.5 8.5L12 4l4.5 4.5M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3')],
  search: [C(11, 11, 6.5), P('M16 16l4.5 4.5')],
  layers: [P('M12 4l8 4-8 4-8-4 8-4zM4 12l8 4 8-4M4 16l8 4 8-4')],
  devices: [R(5, 5, 14, 10, 1.5), P('M3 19h18')],
  timer: [C(12, 13.5, 6.5), P('M12 10v3.5l2 1.5M9.5 3.5h5')],
  key: [C(8, 15, 4), P('M11 12l8.5-8.5M16 7l2.5 2.5M13.5 9.5l2 2')],
};

export function icon(name, size = 18) {
  const svg = document.createElementNS(NS, 'svg');
  for (const [k, v] of Object.entries({
    viewBox: '0 0 24 24', width: size, height: size, fill: 'none', stroke: 'currentColor',
    'stroke-width': 1.75, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', class: 'ic',
  })) svg.setAttribute(k, v);
  for (const [tag, attrs] of SHAPES[name]) {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) if (v != null) el.setAttribute(k, v);
    svg.append(el);
  }
  return svg;
}
