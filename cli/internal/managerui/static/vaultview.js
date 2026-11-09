// 变量库详情：变量表格，添加、编辑、导入、复制和删除都在这里。
import { call } from './api.js';
import { confirmBox, glyph, h, iconButton, labeled, mount, run, toast } from './dom.js';
import { icon } from './icons.js';
import { copyDialog, importDialog, nameDialog, varDialog } from './dialogs.js';

// valueCell 是值那一格：解不开、已显示、遮住三种情况。
export function valueCell(v, open, value) {
  if (v.broken) return h('span', { class: 'broken', text: '无法解密。可以勾选后删除，或点编辑重新填写。' });
  if (open) return h('code', { class: value === '' ? 'empty' : '', text: value === '' ? '（空值）' : value });
  return h('span', { class: 'masked' }, h('span', { class: 'dots', 'aria-hidden': 'true', text: v.length ? '•'.repeat(Math.min(v.length, 12)) : '' }),
    h('span', { class: 'len', text: v.length ? `${v.length} 个字符` : '空值' }));
}

// vaultView 管理一个变量库。ctx 提供 main（右侧区域）、vaults()、reload()、select()。
export function vaultView(ctx, vaultId) {
  const { main } = ctx;
  let vars = []; // { name, length, note, broken }
  let filter = '';
  const shown = new Map(); // 变量名 → 已显示的值
  const picked = new Set();
  const vault = () => ctx.vaults().find((v) => v.id === vaultId);
  const value = async (name) => (await call('/api/vars/value', { vault: vaultId, name })).value;

  async function load() {
    vars = (await call('/api/vars/list', { vault: vaultId })).vars;
    const have = new Set(vars.map((v) => v.name));
    for (const n of [...picked]) if (!have.has(n)) picked.delete(n);
    for (const n of [...shown.keys()]) {
      if (!have.has(n)) shown.delete(n);
      else shown.set(n, await value(n));
    }
  }

  async function rename() {
    const v = vault();
    if (await nameDialog('变量库改名', '变量库名', v.name, '保存', (name) => call('/api/vaults/rename', { vault: v.id, name }).then(() => true))) ctx.reload();
  }

  async function remove() {
    const v = vault();
    const lines = [`将删除变量库“${v.name}”和其中的 ${v.count} 个变量，删除后无法恢复。`];
    if (v.envs.length) {
      lines.push(`下面 ${v.envs.length} 个环境引用了它，删除后这些引用会显示为“已失效”，不再提供变量，需要到环境里删掉或换成其他变量库：`,
        h('ul', { class: 'names' }, v.envs.map((n) => h('li', { text: n }))));
    }
    if (!await confirmBox('删除变量库', lines, '删除变量库', { danger: true })) return;
    try {
      await call('/api/vaults/delete', { vault: v.id });
      toast(`已删除变量库“${v.name}”。`);
      ctx.select(null);
    } catch (err) {
      if (!err.fatal) toast(err.message, 'error');
      ctx.reload();
    }
  }

  async function deletePicked() {
    const chosen = [...picked];
    const v = vault();
    const ok = await confirmBox('删除变量', [
      `将从变量库“${v.name}”删除这 ${chosen.length} 个变量，引用它们的环境${v.envs.length ? `（${v.envs.join('、')}）` : ''}和所有设备都会失去它们：`,
      h('ul', { class: 'names' }, chosen.map((n) => h('li', { class: 'mono', text: n }))),
    ], `删除 ${chosen.length} 个变量`, { danger: true });
    if (!ok) return;
    try {
      const { results } = await call('/api/vars/delete', { vault: vaultId, names: chosen });
      const failed = results.filter((r) => r.error);
      if (failed.length) toast(`${failed.length} 个变量没有删除成功：${failed.map((r) => `${r.name}（${r.error}）`).join('；')}`, 'error');
      else toast(`已删除 ${chosen.length} 个变量。`);
      picked.clear();
    } catch (err) {
      if (!err.fatal) toast(err.message, 'error');
    }
    ctx.reload();
  }

  async function toggle(name, btn) {
    if (shown.has(name)) {
      shown.delete(name);
      return render();
    }
    await run(btn, '', null, async () => {
      shown.set(name, await value(name));
      render();
    });
  }

  function copyValue(name, btn) {
    run(btn, '', null, async () => {
      await navigator.clipboard.writeText(await value(name));
      toast(`已复制 ${name} 的值。用完后请清空剪贴板。`);
    });
  }

  const openImport = async (text = '') => { if (await importDialog(vault(), text)) ctx.reload(); };
  const openAdd = async () => { if (await varDialog(vaultId, null)) ctx.reload(); };

  function row(v) {
    const name = v.name;
    const open = shown.has(name);
    const show = iconButton(open ? 'eyeOff' : 'eye', open ? `隐藏 ${name} 的值` : `显示 ${name} 的值`, { disabled: v.broken });
    show.onclick = () => toggle(name, show);
    const copy = iconButton('copy', `复制 ${name} 的值`, { disabled: v.broken });
    copy.onclick = () => copyValue(name, copy);
    const box = h('input', { type: 'checkbox', checked: picked.has(name), 'aria-label': `选择 ${name}` });
    box.onchange = () => {
      if (box.checked) picked.add(name);
      else picked.delete(name);
      render();
    };
    return h('tr', { class: picked.has(name) ? 'on' : '' },
      h('td', { class: 'tick' }, box),
      h('td', { class: 'name' }, h('span', { class: 'mono', text: name }),
        v.note && h('span', { class: 'note', title: v.note, text: v.note.split('\n')[0] })),
      h('td', { class: 'value' }, valueCell(v, open, shown.get(name))),
      h('td', { class: 'ops' }, show, copy,
        iconButton('edit', `编辑 ${name}`, { onclick: async () => { if (await varDialog(vaultId, v)) ctx.reload(); } })));
  }

  function render() {
    const v = vault();
    if (!v) return;
    // 重画后把光标还给筛选框：输入筛选词和其他设备的修改都会触发重画。
    const typing = main.contains(document.activeElement) && document.activeElement.type === 'search';
    const q = filter.toLowerCase();
    const visible = vars.filter((x) => x.name.toLowerCase().includes(q) || x.note.toLowerCase().includes(q));
    const all = h('input', { type: 'checkbox', 'aria-label': '全选', checked: visible.length > 0 && visible.every((x) => picked.has(x.name)) });
    all.onchange = () => {
      for (const x of visible) {
        if (all.checked) picked.add(x.name);
        else picked.delete(x.name);
      }
      render();
    };
    const search = h('input', { type: 'search', placeholder: `在 ${vars.length} 个变量里按名称或备注筛选`, value: filter, 'aria-label': '按名称或备注筛选', spellcheck: false });
    search.oninput = () => {
      filter = search.value;
      render();
    };
    const others = ctx.vaults().length > 1;
    mount(main,
      h('header', { class: 'env-head' },
        h('div', { class: 'env-title' }, h('span', { class: 'kind' }, icon('vault', 16), '变量库'), h('h1', { text: v.name }),
          iconButton('edit', '变量库改名', { onclick: rename }),
          iconButton('trash', '删除变量库', { onclick: remove })),
        h('ul', { class: 'facts' },
          h('li', {}, icon('key', 16), h('b', { text: String(v.count) }), ' 个变量'),
          h('li', { title: v.envs.join('、') || '还没有环境引用它' }, icon('layers', 16), v.envs.length ? [h('b', { text: String(v.envs.length) }), ' 个环境引用'] : '没有环境引用'))),
      picked.size
        ? h('div', { class: 'bar picked' }, h('b', { text: `已选 ${picked.size} 个` }),
          labeled('copy', '复制到其他变量库', { class: 'small', disabled: !others, title: others ? null : '需要先有另一个变量库', onclick: async () => { if (await copyDialog(v, [...picked], ctx.vaults())) { picked.clear(); ctx.reload(); } } }),
          labeled('trash', '删除所选', { class: 'small danger', onclick: deletePicked }),
          h('button', { type: 'button', class: 'ghost small', text: '取消选择', onclick: () => { picked.clear(); render(); } }))
        : h('div', { class: 'bar' }, h('label', { class: 'search' }, icon('search', 16), search),
          labeled('upload', '批量导入', { onclick: () => openImport() }),
          labeled('plus', '添加变量', { class: 'primary', onclick: openAdd })),
      v.envs.length === 0 && h('p', { class: 'warn small', text: '还没有环境引用这个变量库，电脑拿不到其中的变量。到左侧“环境”里新建或编辑一个环境，添加对它的引用。' }),
      vars.length > 0 && h('div', { class: 'table' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', { class: 'tick' }, all), h('th', { text: '名称' }), h('th', { text: '值' }), h('th', { class: 'ops' }, h('span', { class: 'sr', text: '操作' })))),
        h('tbody', {}, visible.map(row), visible.length === 0 && h('tr', {}, h('td', { colSpan: 4, class: 'mute none', text: `没有名称或备注包含“${filter}”的变量。` }))))),
      h('button', { type: 'button', class: vars.length ? 'drop' : 'drop tall', onclick: () => openImport() },
        glyph('file', vars.length ? 44 : 84),
        h('span', {}, h('b', { text: vars.length ? '把 .env 文件拖到这里，批量导入' : '这个变量库还没有变量' }),
          h('span', { text: vars.length ? '也可以点这里粘贴内容。写入前会先列出新增和修改的变量，由你确认。' : '把 .env 文件拖到这里，或点这里粘贴内容，一次导入一批；也可以用右上角的“添加变量”逐个添加。' }))));
    if (typing && search.isConnected) search.focus();
  }

  return { load, render, dropFile: (text) => openImport(text) };
}
