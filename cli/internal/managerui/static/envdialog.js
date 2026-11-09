// 新建变量库，以及新建、编辑环境的引用（设计文档 17.1）。
import { call } from './api.js';
import { field, h, iconButton, labeled, modal, mount, run, toast } from './dom.js';

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;

// vaultDialog 新建变量库，默认同时新建同名环境；返回 { id, envId }。
export function vaultDialog() {
  return modal('新建变量库', (close) => {
    const input = h('input', { type: 'text', maxLength: 64, required: true, placeholder: '例如：OpenAI、博客生产' });
    const withEnv = h('input', { type: 'checkbox', checked: true });
    const error = h('p', { class: 'error', role: 'alert' });
    const submit = h('button', { class: 'primary', type: 'submit', text: '新建' });
    setTimeout(() => input.focus());
    return h('form', {
      class: 'stack',
      onsubmit: (ev) => {
        ev.preventDefault();
        run(submit, '正在新建……', error, async () => {
          const r = await call('/api/vaults/create', { name: input.value, withEnv: withEnv.checked });
          if (r.warning) toast(r.warning, 'error');
          close(r);
        });
      },
    },
    h('p', { class: 'mute', text: '变量库保存变量。电脑通过环境拿到变量库里的变量，所以通常还要有一个引用它的环境。' }),
    field('变量库名', input),
    h('label', { class: 'check' }, withEnv, h('span', {}, h('b', { text: '同时创建同名环境' }),
      h('span', { class: 'hint', text: '引用这个变量库的全部变量，可以修改。之后在手机上把这个环境授权给电脑即可使用。' }))),
    error,
    h('div', { class: 'actions' }, h('button', { type: 'button', text: '取消', onclick: () => close() }), submit));
  });
}

// envDialog 新建（env 为空）或编辑环境的名字和引用；保存成功返回环境 ID。
export function envDialog(vaults, env) {
  return modal(env ? `编辑环境“${env.name}”` : '新建环境', (close) => {
    const nameIn = h('input', { type: 'text', maxLength: 64, required: true, value: env?.name ?? '', placeholder: '例如：博客、本地开发' });
    // 每条引用：{ vaultId, scope, writable, missing, names: [原名], picked: Set, as: Map(原名 → 新名字) }
    const refs = (env?.refs ?? []).map((r) => ({
      vaultId: r.vaultId, scope: r.scope, writable: r.writable, missing: !!r.missing, names: [],
      picked: new Set(r.scope === 'pick' ? r.items.map((i) => i.name) : []),
      as: new Map(r.items.filter((i) => i.as).map((i) => [i.name, i.as])),
      wanted: r.items.map((i) => i.name),
    }));
    const list = h('div', { class: 'ref-edit' });
    const adder = h('div', { class: 'bar' });
    const preview = h('div', { class: 'preview' });
    const error = h('p', { class: 'error', role: 'alert' });
    const submit = h('button', { class: 'primary', type: 'submit', text: env ? '保存' : '新建' });
    const vaultName = (id) => vaults.find((v) => v.id === id)?.name;
    let timer = 0;

    async function loadNames(r) {
      if (r.missing) return;
      const { names } = await call('/api/vaults/names', { vault: r.vaultId });
      // 勾选了、但变量库里已经没有的变量也列出来，保存时保留。
      r.names = [...names, ...r.wanted.filter((n) => !names.includes(n))];
    }

    function payload() {
      return refs.map((r) => {
        const rename = (n) => (r.as.get(n)?.trim() ? { name: n, as: r.as.get(n).trim() } : { name: n });
        const items = r.scope === 'pick'
          ? r.names.filter((n) => r.picked.has(n)).map(rename)
          : r.names.filter((n) => r.as.get(n)?.trim()).map(rename);
        return { vaultId: r.vaultId, scope: r.scope, writable: r.writable, items };
      });
    }

    function badNames() {
      return refs.flatMap((r) => [...r.as.values()].map((a) => a.trim()).filter((a) => a && !NAME_RE.test(a)));
    }

    function schedule() {
      clearTimeout(timer);
      timer = setTimeout(updatePreview, 150);
    }

    async function updatePreview() {
      const bad = badNames();
      if (bad.length) {
        submit.disabled = true;
        return mount(preview, h('p', { class: 'error', text: `新的名字只能包含字母、数字和下划线，不能以数字开头：${bad.join('、')}` }));
      }
      try {
        const { items, shadowed, duplicates } = await call('/api/envs/preview', { refs: payload() });
        submit.disabled = duplicates.length > 0;
        mount(preview,
          duplicates.length > 0
            ? h('p', { class: 'error', text: `有重名的变量：${duplicates.join('、')}。给其中一个改名，或取消勾选后才能保存。` })
            : h('p', { class: 'mute', text: `保存后这个环境里有 ${items.length} 个变量${items.length ? `：${items.map((i) => i.name).join('、')}` : ''}。` }),
          shadowed.length > 0 && h('p', { class: 'warn small', text: `被遮住的同名变量：${shadowed.map((s) => s.name).join('、')}（排在前面的引用优先）。` }));
      } catch (e) {
        if (!e.fatal) mount(preview, h('p', { class: 'error', text: e.message }));
      }
    }

    function move(i, d) {
      const [r] = refs.splice(i, 1);
      refs.splice(i + d, 0, r);
      render();
    }

    function refBlock(r, i) {
      const head = h('div', { class: 'ref-head' },
        h('b', { text: r.missing ? '已失效的引用' : vaultName(r.vaultId) }),
        h('span', { class: 'grow' }),
        iconButton('up', '往前移', { disabled: i === 0, onclick: () => move(i, -1) }),
        iconButton('down', '往后移', { disabled: i === refs.length - 1, onclick: () => move(i, 1) }),
        iconButton('trash', '删除这条引用', { onclick: () => { refs.splice(i, 1); render(); } }));
      if (r.missing) {
        return h('div', { class: 'ref-card missing' }, head,
          h('p', { class: 'mute small', text: '这个变量库已被删除，这条引用不再提供变量。删掉它，或添加其他变量库。' }));
      }
      const scope = h('select', {}, h('option', { value: 'all', text: '全部变量（以后新增的也包含）' }), h('option', { value: 'pick', text: '勾选的变量' }));
      scope.value = r.scope;
      scope.onchange = () => {
        r.scope = scope.value;
        if (r.scope === 'pick' && r.picked.size === 0) r.names.forEach((n) => r.picked.add(n));
        render();
      };
      const writable = h('input', { type: 'checkbox', checked: r.writable });
      writable.onchange = () => { r.writable = writable.checked; schedule(); };
      const rows = r.names.map((n) => {
        const box = h('input', { type: 'checkbox', checked: r.scope === 'all' || r.picked.has(n), disabled: r.scope === 'all', 'aria-label': `引用 ${n}` });
        box.onchange = () => {
          if (box.checked) r.picked.add(n);
          else r.picked.delete(n);
          schedule();
        };
        const as = h('input', { type: 'text', class: 'mono small', value: r.as.get(n) ?? '', placeholder: '不改名', maxLength: 128, spellcheck: false, 'aria-label': `${n} 在环境里的名字` });
        as.oninput = () => { r.as.set(n, as.value); schedule(); };
        return h('li', {}, h('label', {}, box, h('span', { class: 'mono', text: n })), as);
      });
      return h('div', { class: 'ref-card' }, head,
        field('范围', scope),
        r.names.length
          ? h('ul', { class: 'pick' }, rows)
          : h('p', { class: 'mute small', text: r.scope === 'all' ? '变量库里还没有变量，以后新增的会自动包含。' : '变量库里还没有变量。' }),
        h('label', { class: 'check' }, writable, h('span', {}, h('b', { text: '可以修改' }),
          h('span', { class: 'hint', text: '被授权读写的电脑可以修改这些变量，写回变量库里的原变量；范围是全部变量时还能新增变量。所有引用这个变量库的环境都会看到变化。' }))));
    }

    function render() {
      mount(list, refs.length ? refs.map(refBlock) : h('p', { class: 'mute', text: '还没有引用。从下面选一个变量库添加。' }));
      const free = vaults.filter((v) => !refs.some((r) => r.vaultId === v.id));
      const pick = h('select', { 'aria-label': '要引用的变量库' }, free.map((v) => h('option', { value: v.id, text: `${v.name}（${v.count} 个变量）` })));
      const add = labeled('plus', '添加引用', { class: 'small', disabled: free.length === 0 });
      add.onclick = () => run(add, '', error, async () => {
        const r = { vaultId: pick.value, scope: 'all', writable: false, missing: false, names: [], picked: new Set(), as: new Map(), wanted: [] };
        await loadNames(r);
        refs.push(r);
        render();
      });
      mount(adder, free.length ? [pick, add] : h('p', { class: 'mute small', text: vaults.length ? '全部变量库都已引用。' : '还没有变量库，先到左侧新建一个。' }));
      schedule();
    }

    (async () => {
      try {
        await Promise.all(refs.map(loadNames));
      } catch (e) {
        error.textContent = e.message;
      }
      render();
    })();
    setTimeout(() => nameIn.focus());

    return h('form', {
      class: 'stack',
      onsubmit: (ev) => {
        ev.preventDefault();
        run(submit, '正在保存……', error, async () => {
          const body = { name: nameIn.value, refs: payload() };
          const id = env ? (await call('/api/envs/save', { env: env.id, ...body }), env.id) : (await call('/api/envs/create', body)).id;
          toast(env ? `已保存环境“${nameIn.value.trim()}”。` : `已新建环境“${nameIn.value.trim()}”。到手机上把它授权给电脑即可使用。`);
          close(id);
        });
      },
    },
    field('环境名', nameIn),
    h('div', { class: 'field' }, h('span', { class: 'label', text: '引用的变量库' }),
      h('span', { class: 'hint', text: '环境不保存变量，只引用变量库里的变量，可以给变量改名。同名时排在前面的引用优先。' }), list, adder),
    preview, error,
    h('div', { class: 'actions' }, h('button', { type: 'button', text: '取消', onclick: () => close() }), submit));
  }, { wide: true });
}
