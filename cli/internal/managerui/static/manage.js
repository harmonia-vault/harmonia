// 解锁后的管理界面：一张“账本”，左栏是环境和这次会话，右边是所选环境的变量表格。
import { call, idleFor } from './api.js';
import { brand, confirmBox, glyph, h, iconButton, labeled, mount, run, toast } from './dom.js';
import { icon } from './icons.js';
import { copyDialog, importDialog, nameDialog, settingsDialog, varDialog } from './dialogs.js';

const IDLE_LIMIT = 5 * 60 * 1000;

export function manageView(st, apply) {
  let rev = st.rev;
  let envs = [];
  let envId = null;
  let vars = []; // { name, length }
  let filter = '';
  let loaded = false;
  const shown = new Map(); // 变量名 → 已显示的值
  const picked = new Set();

  const list = h('nav', { class: 'env-list', 'aria-label': '环境' });
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
      h('div', { class: 'rail-head' }, h('h2', { text: '环境' }), iconButton('plus', '新建环境', { onclick: () => createEnv() })),
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

  const env = () => envs.find((e) => e.id === envId);
  const names = () => vars.map((v) => v.name);

  async function refresh() {
    try {
      envs = (await call('/api/envs/list')).envs;
      if (!env()) {
        envId = envs[0]?.id ?? null;
        shown.clear();
        picked.clear();
      }
      vars = envId ? (await call('/api/vars/list', { env: envId })).vars : [];
      const have = new Set(names());
      for (const n of [...picked]) if (!have.has(n)) picked.delete(n);
      for (const n of [...shown.keys()]) {
        if (!have.has(n)) shown.delete(n);
        else shown.set(n, (await call('/api/vars/value', { env: envId, name: n })).value);
      }
    } catch (e) {
      if (!e.fatal && e.code !== 'locked' && e.code !== 'revoked') toast(e.message, 'error');
      return;
    }
    loaded = true;
    render();
  }

  function select(id) {
    envId = id;
    filter = '';
    shown.clear();
    picked.clear();
    refresh();
  }

  async function createEnv() {
    const id = await nameDialog('新建环境', '环境名', '', '新建', (name) => call('/api/envs/create', { name }).then((r) => r.id));
    if (id) select(id);
  }

  async function renameEnv() {
    const e = env();
    if (await nameDialog('环境改名', '环境名', e.name, '保存', (name) => call('/api/envs/rename', { env: e.id, name }).then(() => true))) refresh();
  }

  async function deleteEnv() {
    const e = env();
    const ok = await confirmBox('删除环境', [
      `将删除环境“${e.name}”和其中的 ${e.count} 个变量。`,
      `能访问它的 ${e.devices} 台设备都会失去这个环境，删除后无法恢复。`,
    ], '删除环境', { danger: true });
    if (!ok) return;
    try {
      await call('/api/envs/delete', { env: e.id });
      toast(`已删除环境“${e.name}”。`);
      envId = null;
    } catch (err) {
      if (!err.fatal) toast(err.message, 'error');
    }
    refresh();
  }

  async function deletePicked() {
    const chosen = [...picked];
    const ok = await confirmBox('删除变量', [
      `将从环境“${env().name}”删除这 ${chosen.length} 个变量，所有设备都会失去它们：`,
      h('ul', { class: 'names' }, chosen.map((n) => h('li', { class: 'mono', text: n }))),
    ], `删除 ${chosen.length} 个变量`, { danger: true });
    if (!ok) return;
    try {
      const { results } = await call('/api/vars/delete', { env: envId, names: chosen });
      const failed = results.filter((r) => r.error);
      if (failed.length) toast(`${failed.length} 个变量没有删除成功：${failed.map((r) => `${r.name}（${r.error}）`).join('；')}`, 'error');
      else toast(`已删除 ${chosen.length} 个变量。`);
      picked.clear();
    } catch (err) {
      if (!err.fatal) toast(err.message, 'error');
    }
    refresh();
  }

  async function toggle(name, btn) {
    if (shown.has(name)) {
      shown.delete(name);
      return renderMain();
    }
    await run(btn, '', null, async () => {
      shown.set(name, (await call('/api/vars/value', { env: envId, name })).value);
      renderMain();
    });
  }

  function copyValue(name, btn) {
    run(btn, '', null, async () => {
      const { value } = await call('/api/vars/value', { env: envId, name });
      await navigator.clipboard.writeText(value);
      toast(`已复制 ${name} 的值。用完后请清空剪贴板。`);
    });
  }

  const openImport = async (text = '') => { if (await importDialog(env(), text)) refresh(); };
  const openAdd = async () => { if (await varDialog(envId, null)) refresh(); };

  // 把 .env 文件拖到右侧任意位置即可开始导入。
  main.addEventListener('dragover', (ev) => {
    if (!env() || !ev.dataTransfer?.types.includes('Files')) return;
    ev.preventDefault();
    main.classList.add('dropping');
  });
  main.addEventListener('dragleave', (ev) => { if (!main.contains(ev.relatedTarget)) main.classList.remove('dropping'); });
  main.addEventListener('drop', async (ev) => {
    main.classList.remove('dropping');
    const file = ev.dataTransfer?.files[0];
    if (!env() || !file) return;
    ev.preventDefault();
    if (file.size > 4 << 20) return toast('这个文件超过 4 MB，不像是 .env 文件。', 'error');
    openImport(await file.text());
  });

  function renderRail() {
    mount(list, envs.map((e) => h('button', {
      type: 'button', class: e.id === envId ? 'env on' : 'env', 'aria-current': e.id === envId ? 'true' : null, onclick: () => select(e.id),
    }, icon('layers', 16), h('span', { class: 'env-name', text: e.name }), h('span', { class: 'count', text: String(e.count) }))),
    envs.length === 0 && loaded && h('p', { class: 'mute small', text: '还没有环境。' }));
  }

  // valueCell 是值那一格：解不开、已显示、遮住三种情况。
  function valueCell(v, open, value) {
    if (v.broken) return h('span', { class: 'broken', text: '无法解密。可以勾选后删除，或点编辑重新填写。' });
    if (open) return h('code', { class: value === '' ? 'empty' : '', text: value === '' ? '（空值）' : value });
    return h('span', { class: 'masked' }, h('span', { class: 'dots', 'aria-hidden': 'true', text: v.length ? '•'.repeat(Math.min(v.length, 12)) : '' }),
      h('span', { class: 'len', text: v.length ? `${v.length} 个字符` : '空值' }));
  }

  function row(v) {
    const name = v.name;
    const open = shown.has(name);
    const value = shown.get(name);
    const show = iconButton(open ? 'eyeOff' : 'eye', open ? `隐藏 ${name} 的值` : `显示 ${name} 的值`, { disabled: v.broken });
    show.onclick = () => toggle(name, show);
    const copy = iconButton('copy', `复制 ${name} 的值`, { disabled: v.broken });
    copy.onclick = () => copyValue(name, copy);
    const box = h('input', { type: 'checkbox', checked: picked.has(name), 'aria-label': `选择 ${name}` });
    box.onchange = () => {
      if (box.checked) picked.add(name);
      else picked.delete(name);
      renderMain();
    };
    return h('tr', { class: picked.has(name) ? 'on' : '' },
      h('td', { class: 'tick' }, box),
      h('td', { class: 'name' }, h('span', { class: 'mono', text: name }),
        v.note && h('span', { class: 'note', title: v.note, text: v.note.split('\n')[0] })),
      h('td', { class: 'value' }, valueCell(v, open, value)),
      h('td', { class: 'ops' }, show, copy,
        iconButton('edit', `编辑 ${name}`, { onclick: async () => { if (await varDialog(envId, v)) refresh(); } })));
  }

  function renderMain() {
    const e = env();
    if (!loaded) return mount(main, h('p', { class: 'mute pad', text: '正在读取……' }));
    if (!e) {
      return mount(main, h('div', { class: 'blank' }, glyph('file', 96),
        h('h1', { text: '先建一个环境' }),
        h('p', { text: '环境是一组变量，例如“OpenAI”“生产环境”。建好后往里添加或批量导入变量，再到手机上决定哪些电脑可以使用它。' }),
        labeled('plus', '新建环境', { class: 'primary big', onclick: createEnv })));
    }
    // 重画后把光标还给筛选框：输入筛选词和其他设备的修改都会触发重画。
    const typing = main.contains(document.activeElement) && document.activeElement.type === 'search';
    const q = filter.toLowerCase();
    const visible = vars.filter((v) => v.name.toLowerCase().includes(q) || v.note.toLowerCase().includes(q));
    const all = h('input', { type: 'checkbox', 'aria-label': '全选', checked: visible.length > 0 && visible.every((v) => picked.has(v.name)) });
    all.onchange = () => {
      for (const v of visible) {
        if (all.checked) picked.add(v.name);
        else picked.delete(v.name);
      }
      renderMain();
    };
    const search = h('input', { type: 'search', placeholder: `在 ${vars.length} 个变量里按名称或备注筛选`, value: filter, 'aria-label': '按名称或备注筛选', spellcheck: false });
    search.oninput = () => {
      filter = search.value;
      renderMain();
    };
    mount(main,
      h('header', { class: 'env-head' },
        h('div', { class: 'env-title' }, h('h1', { text: e.name }),
          iconButton('edit', '环境改名', { onclick: renameEnv }),
          iconButton('trash', '删除环境', { onclick: deleteEnv })),
        h('ul', { class: 'facts' },
          h('li', {}, icon('key', 16), h('b', { text: String(e.count) }), ' 个变量'),
          h('li', { title: '全部管理设备，加上在手机上授权了这个环境的电脑' }, icon('devices', 16), h('b', { text: String(e.devices) }), ' 台设备可以读取'))),
      picked.size
        ? h('div', { class: 'bar picked' }, h('b', { text: `已选 ${picked.size} 个` }),
          labeled('copy', '复制到其他环境', { class: 'small', disabled: envs.length < 2, title: envs.length < 2 ? '需要先有另一个环境' : null, onclick: async () => { if (await copyDialog(e, [...picked], envs)) { picked.clear(); refresh(); } } }),
          labeled('trash', '删除所选', { class: 'small danger', onclick: deletePicked }),
          h('button', { type: 'button', class: 'ghost small', text: '取消选择', onclick: () => { picked.clear(); renderMain(); } }))
        : h('div', { class: 'bar' }, h('label', { class: 'search' }, icon('search', 16), search),
          labeled('upload', '批量导入', { onclick: () => openImport() }),
          labeled('plus', '添加变量', { class: 'primary', onclick: openAdd })),
      vars.length > 0 && h('div', { class: 'table' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', { class: 'tick' }, all), h('th', { text: '名称' }), h('th', { text: '值' }), h('th', { class: 'ops' }, h('span', { class: 'sr', text: '操作' })))),
        h('tbody', {}, visible.map(row), visible.length === 0 && h('tr', {}, h('td', { colSpan: 4, class: 'mute none', text: `没有名称或备注包含“${filter}”的变量。` }))))),
      h('button', { type: 'button', class: vars.length ? 'drop' : 'drop tall', onclick: () => openImport() },
        glyph('file', vars.length ? 44 : 84),
        h('span', {}, h('b', { text: vars.length ? '把 .env 文件拖到这里，批量导入' : '这个环境还没有变量' }),
          h('span', { text: vars.length ? '也可以点这里粘贴内容。写入前会先列出新增和修改的变量，由你确认。' : '把 .env 文件拖到这里，或点这里粘贴内容，一次导入一批；也可以用右上角的“添加变量”逐个添加。' }))));
    if (typing && search.isConnected) search.focus();
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
