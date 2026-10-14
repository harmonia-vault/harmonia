// 管理页面入口：按 harmonia 报告的阶段显示对应的界面。
import { getState, setPace, start, watch } from './api.js';
import { brand, h, mount, toast } from './dom.js';
import { loginView, pairingView, lockedView, brokenView } from './auth.js';
import { manageView } from './manage.js';

const root = document.getElementById('app');
let current = { key: '', view: null };

function fatal(e) {
  current = { key: 'fatal', view: null };
  for (const d of document.querySelectorAll('dialog')) d.remove();
  mount(root, h('main', { class: 'gate solo' }, h('section', { class: 'card stack' }, brand(),
    h('h1', { text: '页面已断开' }),
    h('p', { text: e.message }),
    h('p', { class: 'mute', text: '已解开的密钥只在 harmonia 进程的内存里，进程结束后就没有了。' }))));
}

const views = { login: loginView, pairing: pairingView, locked: lockedView, unlocked: manageView, broken: brokenView };

// apply 在阶段变化时换界面；阶段不变时只把新状态交给当前界面。
export function apply(st) {
  if (current.key === 'fatal') return;
  if (st.notice && st.phase !== 'broken') toast(st.notice);
  setPace(st.phase === 'pairing' ? 1500 : 5000);
  const key = st.phase === 'pairing' ? `pairing:${st.pairing.code}` : st.phase;
  if (key !== current.key) {
    for (const d of document.querySelectorAll('dialog')) d.remove();
    current.view?.dispose?.();
    const view = views[st.phase](st, apply);
    current = { key, view };
    mount(root, view.el);
    view.focus?.();
  } else {
    current.view?.update?.(st);
  }
}

(async () => {
  try {
    await start(fatal);
    apply(await getState());
    watch(apply);
  } catch (e) {
    if (current.key !== 'fatal') fatal(e);
  }
})();
