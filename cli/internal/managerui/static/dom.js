// 页面元素的小工具：只用 DOM 接口创建元素，不拼接 HTML。
import { icon } from './icons.js';

export function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k.includes('-') || k === 'for' || k === 'role' || !(k in el)) el.setAttribute(k, v === true ? '' : v);
    else el[k] = v;
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid);
  return el;
}

export function mount(parent, ...kids) {
  parent.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false));
}

export function toast(message, kind = 'info') {
  const el = h('div', { class: `toast ${kind}`, text: message });
  document.getElementById('toasts').append(el);
  setTimeout(() => el.remove(), kind === 'error' ? 8000 : 5000);
}

// 口令输入框：不让浏览器和密码管理器保存或自动填充。
export function secretInput(props = {}) {
  return h('input', {
    type: 'password', autocomplete: 'off', autocapitalize: 'off', spellcheck: false,
    'data-1p-ignore': true, 'data-lpignore': 'true', 'data-bwignore': true, 'data-form-type': 'other', ...props,
  });
}

export function field(label, input, hint) {
  return h('label', { class: 'field' }, h('span', { class: 'label', text: label }), input, hint && h('span', { class: 'hint', text: hint }));
}

// run 在操作进行期间禁用按钮并换成进行中的文字；失败时把原因显示在 errorEl 里（没有就弹出提示）。
export async function run(button, busyText, errorEl, fn) {
  const target = button.querySelector('span') || button;
  const label = target.textContent;
  button.disabled = true;
  if (busyText) target.textContent = busyText;
  if (errorEl) errorEl.textContent = '';
  try {
    return await fn();
  } catch (e) {
    if (e.fatal) return undefined;
    if (errorEl) errorEl.textContent = e.message;
    else toast(e.message, 'error');
    return undefined;
  } finally {
    button.disabled = false;
    target.textContent = label;
  }
}

// iconButton 是只有图标的按钮；label 同时用作无障碍名称和悬停提示。
export function iconButton(name, label, props = {}) {
  return h('button', { type: 'button', class: 'ghost icon', 'aria-label': label, title: label, ...props }, icon(name));
}

// labeled 是带图标的文字按钮。
export function labeled(name, text, props = {}) {
  return h('button', { type: 'button', ...props }, icon(name, 16), h('span', { text }));
}

// glyph 是手绘风格的插图（与实例首页相同），深色模式下换用浅色线条的那一份。
export function glyph(name, size) {
  return h('picture', { class: 'glyph' },
    h('source', { srcset: `${name}-dark.svg`, media: '(prefers-color-scheme: dark)' }),
    h('img', { src: `${name}.svg`, alt: '', width: size, height: size }));
}

// modal 打开一个对话框。build 收到 close 函数，返回对话框的内容；对话框关闭时返回 close 传入的值。
export function modal(title, build, { wide = false } = {}) {
  return new Promise((resolve) => {
    let result;
    const dialog = h('dialog', { class: wide ? 'modal wide' : 'modal', 'aria-label': title });
    const close = (value) => {
      result = value;
      dialog.close();
    };
    dialog.append(
      h('header', {}, h('h2', { text: title }), iconButton('close', '关闭', { onclick: () => close() })),
      h('div', { class: 'modal-body' }, build(close)),
    );
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(result);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

export function confirmBox(title, lines, action, { danger = false } = {}) {
  return modal(title, (close) => [
    lines.map((l) => (typeof l === 'string' ? h('p', { text: l }) : l)),
    h('div', { class: 'actions' },
      h('button', { type: 'button', text: '取消', onclick: () => close(false) }),
      h('button', { type: 'button', class: danger ? 'danger' : 'primary', text: action, onclick: () => close(true) })),
  ]);
}

export function brand() {
  return h('div', { class: 'brand' },
    h('picture', {},
      h('source', { srcset: 'icon-dark.svg', media: '(prefers-color-scheme: dark)' }),
      h('img', { src: 'icon.svg', alt: '', width: 40, height: 40 })),
    h('strong', { text: 'Harmonia 管理' }));
}

export const STATUS = { new: '新增', changed: '修改', same: '不变' };
