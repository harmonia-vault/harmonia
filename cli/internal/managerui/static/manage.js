// 解锁后的管理界面：左栏切换环境与变量库，右边显示所选条目的详情。
import { call, idleFor } from './api.js';
import { brand, glyph, h, labeled, mount, run, toast } from './dom.js';
import { icon } from './icons.js';
import { settingsDialog } from './dialogs.js';
import { envDialog, vaultDialog } from './envdialog.js';
import { envView } from './envview.js';
import { vaultView } from './vaultview.js';

const IDLE_LIMIT = 5 * 60 * 1000;

export function manageView(st, apply) {
  let rev = st.rev;
  let envs = [];
  let vaults = [];
  let kind = 'env';
  const remembered = { env: null, vault: null }; // 两类列表分别保留本次会话的选择。
  let sel = null; // { kind: 'env' | 'vault', id }
  let view = null; // 当前详情：{ key, load, render, dropFile? }
  let loaded = false;

  const list = h('nav', { class: 'env-list' });
  const categories = [
    labeled('layers', '环境', { onclick: () => switchKind('env') }),
    labeled('vault', '变量库', { onclick: () => switchKind('vault') }),
  ];
  const listTitle = h('h2');
  const create = labeled('plus', '新建', { class: 'small', onclick: () => kind === 'env' ? createEnv() : createVault() });
  const main = h('section', { class: 'vars' });
  const countdown = h('b', { class: 'mono' });
  const lock = labeled('lock', '锁定', { class: 'small' });
  lock.onclick = () => run(lock, '', null, async () => apply(await call('/api/lock')));
  const a = st.account;
  const el = h('div', { class: 'sheet' },
    h('header', { class: 'top' }, brand(),
      h('span', { class: 'autolock', title: '5 分钟没有操作会自动锁定' }, icon('timer', 16), countdown, h('span', { text: '后自动锁定' })),
      lock),
    h('aside', { class: 'rail' },
      h('div', { class: 'rail-switch', role: 'group', 'aria-label': '管理分类' }, categories),
      h('div', { class: 'rail-head' }, listTitle, create),
      list,
      h('div', { class: 'me' },
        h('dl', {},
          h('dt', { text: '账号' }), h('dd', { text: a.email }),
          h('dt', { text: '这台电脑' }), h('dd', { text: a.deviceName }),
          h('dt', { text: '服务器' }), h('dd', { text: a.server.replace(/^https?:\/\//, '') })),
        labeled('settings', '口令与退出', { class: 'wide small', onclick: () => settingsDialog(a, apply) }))),
    main);

  const tick = () => {
    const s = Math.max(0, Math.ceil((IDLE_LIMIT - idleFor()) / 1000));
    countdown.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  };
  tick();
  const timer = setInterval(tick, 1000);

  const ctx = { main, vaults: () => vaults, envs: () => envs, reload: () => refresh(), select: (next) => select(next) };
  const exists = (s) => s && (s.kind === 'env' ? envs : vaults).some((x) => x.id === s.id);

  async function refresh() {
    try {
      [envs, vaults] = await Promise.all([call('/api/envs/list').then((r) => r.envs), call('/api/vaults/list').then((r) => r.vaults)]);
      if (!loaded && !envs.length && vaults.length) kind = 'vault';
      if (!exists(sel)) {
        const last = { kind, id: remembered[kind] };
        const first = (kind === 'env' ? envs : vaults)[0];
        sel = exists(last) ? last : first ? { kind, id: first.id } : null;
      }
      if (sel) remembered[kind] = sel.id;
      const key = sel && `${sel.kind}:${sel.id}`;
      if (view?.key !== key) view = sel ? { key, ...(sel.kind === 'env' ? envView : vaultView)(ctx, sel.id) } : null;
      await view?.load();
    } catch (e) {
      if (!e.fatal && e.code !== 'locked' && e.code !== 'revoked') toast(e.message, 'error');
      return;
    }
    loaded = true;
    render();
  }

  function select(next) {
    sel = next;
    if (next) {
      kind = next.kind;
      remembered[kind] = next.id;
    }
    view = null;
    refresh();
  }

  function switchKind(next) {
    if (kind === next) return;
    kind = next;
    select(null);
  }

  async function createVault() {
    const r = await vaultDialog();
    if (r) select({ kind: 'vault', id: r.id });
  }

  async function createEnv() {
    const id = await envDialog(vaults, null);
    if (id) select({ kind: 'env', id });
  }

  // 把 .env 文件拖到右侧任意位置即可开始导入（只在变量库里）。
  main.addEventListener('dragover', (ev) => {
    if (!view?.dropFile || !ev.dataTransfer?.types.includes('Files')) return;
    ev.preventDefault();
    main.classList.add('dropping');
  });
  main.addEventListener('dragleave', (ev) => { if (!main.contains(ev.relatedTarget)) main.classList.remove('dropping'); });
  main.addEventListener('drop', async (ev) => {
    main.classList.remove('dropping');
    const file = ev.dataTransfer?.files[0];
    if (!view?.dropFile || !file) return;
    ev.preventDefault();
    if (file.size > 4 << 20) return toast('这个文件超过 4 MB，不像是 .env 文件。', 'error');
    view.dropFile(await file.text());
  });

  function item(kind, x, glyphName, badge) {
    const on = sel?.kind === kind && sel.id === x.id;
    return h('button', {
      type: 'button', class: on ? 'env on' : 'env', 'aria-current': on ? 'true' : null, onclick: () => select({ kind, id: x.id }),
    }, icon(glyphName, 16), h('span', { class: 'env-name', text: x.name }), badge, h('span', { class: 'count', text: String(x.count) }));
  }

  function renderRail() {
    const isEnv = kind === 'env';
    const label = isEnv ? '环境' : '变量库';
    const entries = isEnv ? envs : vaults;
    categories[0].setAttribute('aria-pressed', String(isEnv));
    categories[1].setAttribute('aria-pressed', String(!isEnv));
    listTitle.textContent = `${entries.length} 个${label}`;
    list.setAttribute('aria-label', label);
    create.setAttribute('aria-label', `新建${label}`);
    mount(list, entries.map((x) => item(kind, x, isEnv ? 'layers' : 'vault',
      isEnv && x.problems > 0 && h('span', { class: 'flag', title: `${x.problems} 个问题需要处理`, text: '!' }))),
      entries.length === 0 && loaded && h('p', { class: 'mute small rail-empty', text: `还没有${label}。` }));
  }

  function renderMain() {
    if (!loaded) return mount(main, h('p', { class: 'mute pad', text: '正在读取……' }));
    if (view) return view.render();
    if (kind === 'vault') {
      return mount(main, h('div', { class: 'blank' }, glyph('file', 96),
        h('h1', { text: '先建一个变量库' }),
        h('p', { text: '变量库保存变量，例如“OpenAI”“博客生产”。环境引用变量库里的变量，再到手机上决定哪些电脑可以使用哪个环境。' }),
        labeled('plus', '新建变量库', { class: 'primary big', onclick: createVault })));
    }
    return mount(main, h('div', { class: 'blank' }, glyph('file', 96),
      h('h1', { text: '新建一个环境' }),
      h('p', { text: '电脑通过环境拿到变量。环境引用一个或多个变量库，可以只选其中几个变量，也可以给变量改名。' }),
      labeled('plus', '新建环境', { class: 'primary big', onclick: createEnv })));
  }

  function render() {
    renderRail();
    renderMain();
  }
  render();

  return {
    el,
    focus: refresh,
    dispose: () => clearInterval(timer),
    update(next) {
      if (next.rev !== rev) {
        rev = next.rev;
        refresh();
      }
    },
  };
}
