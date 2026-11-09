// 环境详情：引用了哪些变量库、最终有哪些变量、哪些同名变量被遮住。
import { call } from './api.js';
import { confirmBox, h, iconButton, labeled, mount, run, toast } from './dom.js';
import { icon } from './icons.js';
import { envDialog } from './envdialog.js';
import { nameDialog } from './dialogs.js';
import { valueCell } from './vaultview.js';

// stored 去掉详情里只用于显示的字段，得到可以提交的引用。
export const stored = (refs) => refs.map((r) => ({ vaultId: r.vaultId, scope: r.scope, writable: r.writable, items: r.items }));

function refSummary(r) {
  if (r.missing) return '变量库已被删除，这条引用已失效，不再提供变量。编辑环境，删掉它或换成其他变量库。';
  const renamed = r.items.filter((i) => i.as);
  const parts = [r.scope === 'all' ? '全部变量（以后新增的也包含）' : `勾选的 ${r.items.length} 个变量`];
  if (renamed.length) parts.push(`改名 ${renamed.map((i) => `${i.name} → ${i.as}`).join('，')}`);
  parts.push(r.writable ? '可以修改' : '不允许修改');
  return parts.join(' · ');
}

// envView 显示一个环境。ctx 提供 main、vaults()、reload()、select()。
export function envView(ctx, envId) {
  const { main } = ctx;
  let env = null; // 详情
  let info = new Map(); // 变量库 ID → (原名 → { length, note, broken })
  const shown = new Map(); // 环境里的名字 → 已显示的值

  async function load() {
    env = await call('/api/envs/get', { env: envId });
    const ids = [...new Set(env.items.map((i) => i.vaultId))];
    info = new Map(await Promise.all(ids.map(async (id) =>
      [id, new Map((await call('/api/vars/list', { vault: id })).vars.map((v) => [v.name, v]))])));
    const names = new Set(env.items.map((i) => i.name));
    for (const n of [...shown.keys()]) {
      const it = env.items.find((i) => i.name === n);
      if (!names.has(n) || !it) shown.delete(n);
      else shown.set(n, await valueOf(it));
    }
  }

  const valueOf = async (it) => (await call('/api/vars/value', { vault: it.vaultId, name: it.source })).value;
  const vaultName = (id) => ctx.vaults().find((v) => v.id === id)?.name ?? '已删除的变量库';

  async function edit() {
    if (await envDialog(ctx.vaults(), env)) ctx.reload();
  }

  async function rename() {
    const save = (name) => call('/api/envs/save', { env: env.id, name, refs: stored(env.refs) }).then(() => true);
    if (await nameDialog('环境改名', '环境名', env.name, '保存', save)) ctx.reload();
  }

  async function remove() {
    const ok = await confirmBox('删除环境', [
      `将删除环境“${env.name}”。被授权这个环境的电脑会失去它，授权一并删除。`,
      '它引用的变量库和其中的变量不受影响。',
    ], '删除环境', { danger: true });
    if (!ok) return;
    try {
      await call('/api/envs/delete', { env: env.id });
      toast(`已删除环境“${env.name}”。`);
      ctx.select(null);
    } catch (err) {
      if (!err.fatal) toast(err.message, 'error');
      ctx.reload();
    }
  }

  function row(it) {
    const v = info.get(it.vaultId)?.get(it.source) ?? { length: 0, note: '', broken: false };
    const open = shown.has(it.name);
    const show = iconButton(open ? 'eyeOff' : 'eye', open ? `隐藏 ${it.name} 的值` : `显示 ${it.name} 的值`, { disabled: v.broken });
    show.onclick = async () => {
      if (open) {
        shown.delete(it.name);
        return render();
      }
      await run(show, '', null, async () => {
        shown.set(it.name, await valueOf(it));
        render();
      });
    };
    const copy = iconButton('copy', `复制 ${it.name} 的值`, { disabled: v.broken });
    copy.onclick = () => run(copy, '', null, async () => {
      await navigator.clipboard.writeText(await valueOf(it));
      toast(`已复制 ${it.name} 的值。用完后请清空剪贴板。`);
    });
    const from = it.source === it.name ? vaultName(it.vaultId) : `${vaultName(it.vaultId)} / ${it.source}`;
    return h('tr', {},
      h('td', { class: 'name' }, h('span', { class: 'mono', text: it.name }),
        h('span', { class: 'note', title: `来自变量库 ${from}`, text: `来自 ${from}${it.writable ? '' : ' · 不允许修改'}` })),
      h('td', { class: 'value' }, valueCell(v, open, shown.get(it.name))),
      h('td', { class: 'ops' }, show, copy,
        iconButton('vault', `打开变量库“${vaultName(it.vaultId)}”`, { onclick: () => ctx.select({ kind: 'vault', id: it.vaultId }) })));
  }

  function problems() {
    const out = [];
    for (const sh of env.shadowed) {
      const winner = env.items.find((i) => i.name === sh.name);
      out.push(`有两个 ${sh.name}：使用变量库“${vaultName(winner?.vaultId)}”中的，“${vaultName(sh.vaultId)}”中的被遮住。编辑环境，给其中一个改名。`);
    }
    const missing = env.refs.filter((r) => r.missing).length;
    if (missing) out.push(`${missing} 条引用已失效（变量库已被删除）。编辑环境，删掉它或换成其他变量库。`);
    return out;
  }

  function render() {
    if (!env) return;
    const issues = problems();
    mount(main,
      h('header', { class: 'env-head' },
        h('div', { class: 'env-title' }, h('span', { class: 'kind' }, icon('layers', 16), '环境'), h('h1', { text: env.name }),
          iconButton('edit', '环境改名', { onclick: rename }),
          iconButton('trash', '删除环境', { onclick: remove })),
        h('ul', { class: 'facts' },
          h('li', {}, icon('key', 16), h('b', { text: String(env.items.length) }), ' 个变量'),
          h('li', { title: '全部管理设备，加上在手机上授权了这个环境的电脑' }, icon('devices', 16), h('b', { text: String(env.devices) }), ' 台设备可以读取'))),
      issues.length > 0 && h('div', { class: 'warn' }, h('b', { text: '需要处理' }), h('ul', { class: 'names' }, issues.map((t) => h('li', { text: t })))),
      h('section', { class: 'refs' },
        h('div', { class: 'refs-head' }, h('h2', { text: '引用的变量库' }), labeled('edit', '编辑引用', { class: 'small', onclick: edit })),
        env.refs.length === 0
          ? h('p', { class: 'mute', text: '这个环境还没有引用任何变量库，所以没有变量。点“编辑引用”添加。' })
          : h('ol', { class: 'ref-list' }, env.refs.map((r) => h('li', { class: r.missing ? 'missing' : '' },
            icon('vault', 16),
            h('span', {}, h('b', { text: r.missing ? '已失效' : r.vaultName }), h('span', { class: 'mute small', text: refSummary(r) })))))),
      env.items.length > 0 && h('div', { class: 'table' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', { text: '名称' }), h('th', { text: '值' }), h('th', { class: 'ops' }, h('span', { class: 'sr', text: '操作' })))),
        h('tbody', {}, env.items.map(row)))),
      h('p', { class: 'mute small', text: '环境不保存变量，变量都在它引用的变量库里。要添加或修改变量，打开对应的变量库；要调整这个环境有哪些变量、叫什么名字，点“编辑引用”。设备授权在手机上设置。' }));
  }

  return { load, render };
}
