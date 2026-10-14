// 管理界面里的对话框：环境名、变量编辑、批量导入、跨环境复制、设置。
import { call } from './api.js';
import { RULE } from './auth.js';
import { STATUS, confirmBox, field, h, modal, mount, run, secretInput, toast } from './dom.js';

// nameDialog 输入一个名称并提交；save 成功时对话框关闭并返回它的结果。
export function nameDialog(title, label, initial, action, save) {
  return modal(title, (close) => {
    const input = h('input', { type: 'text', value: initial, maxLength: 64, required: true });
    const error = h('p', { class: 'error', role: 'alert' });
    const submit = h('button', { class: 'primary', type: 'submit', text: action });
    setTimeout(() => input.select());
    return h('form', {
      class: 'stack',
      onsubmit: (ev) => {
        ev.preventDefault();
        run(submit, '正在保存……', error, async () => close(await save(input.value)));
      },
    }, field(label, input), error, h('div', { class: 'actions' }, h('button', { type: 'button', text: '取消', onclick: () => close() }), submit));
  });
}

// varDialog 添加（name 为空）或编辑一个变量。
export function varDialog(env, name) {
  return modal(name ? '编辑变量' : '添加变量', (close) => {
    const nameIn = h('input', { type: 'text', class: 'mono', value: name || '', readOnly: !!name, required: true, maxLength: 128, placeholder: 'OPENAI_API_KEY', spellcheck: false, autocomplete: 'off' });
    const valueIn = h('textarea', { class: 'mono', rows: 5, spellcheck: false, autocomplete: 'off', placeholder: name ? '正在读取……' : '' });
    const error = h('p', { class: 'error', role: 'alert' });
    const submit = h('button', { class: 'primary', type: 'submit', text: '保存', disabled: !!name });
    if (name) {
      call('/api/vars/value', { env, name }).then(({ value }) => {
        valueIn.value = value;
        valueIn.placeholder = '';
        submit.disabled = false;
        valueIn.focus();
      }).catch((e) => { error.textContent = e.message; });
    } else {
      setTimeout(() => nameIn.focus());
    }
    return h('form', {
      class: 'stack',
      onsubmit: (ev) => {
        ev.preventDefault();
        run(submit, '正在保存……', error, async () => {
          const key = nameIn.value.trim();
          const { results } = await call('/api/vars/set', { env, vars: { [key]: valueIn.value } });
          if (results[0]?.error) throw new Error(results[0].error);
          toast(`已保存 ${key}。`);
          close(true);
        });
      },
    },
      field('名称', nameIn, name ? '名称不能修改；需要改名时请新建一个再删除旧的。' : '只能包含字母、数字和下划线，不能以数字开头。'),
      field('值', valueIn),
      error,
      h('div', { class: 'actions' }, h('button', { type: 'button', text: '取消', onclick: () => close() }), submit));
  });
}

// diffList 列出将要写入的变量和各自的结果（新增、修改、不变），“不变”的默认不勾选。
function diffList(items) {
  const boxes = new Map();
  const el = h('ul', { class: 'diff' }, items.map((it) => {
    const box = h('input', { type: 'checkbox', checked: it.status !== 'same' });
    boxes.set(it.name, box);
    return h('li', {}, h('label', {}, box, h('span', { class: 'mono', text: it.name }), h('span', { class: `tag ${it.status}`, text: STATUS[it.status] })));
  }));
  return { el, boxes, chosen: () => [...boxes].filter(([, b]) => b.checked).map(([n]) => n) };
}

// failures 取出一批写入里没有成功的项。
function failures(results) {
  return results.filter((r) => r.error);
}

function failureList(failed) {
  return h('ul', { class: 'names' }, failed.map((r) => h('li', {}, h('span', { class: 'mono', text: r.name }), `：${r.error}`)));
}

// importDialog 批量导入；initial 是拖入文件时已经读到的内容。
export function importDialog(env, initial = '') {
  return modal(`批量导入到“${env.name}”`, (close) => {
    const body = h('div', { class: 'stack' });
    let done = false;
    let draft = initial;
    const finish = () => close(done);

    const input = () => {
      const text = h('textarea', { class: 'mono', rows: 12, spellcheck: false, autocomplete: 'off', placeholder: 'OPENAI_API_KEY=sk-...\nDATABASE_URL="postgres://..."\n# 以 # 开头的行会被忽略', value: draft });
      const file = h('input', { type: 'file', accept: '.env,.txt,text/plain', hidden: true });
      file.onchange = async () => {
        if (file.files[0]) text.value = await file.files[0].text();
        file.value = '';
      };
      const error = h('p', { class: 'error', role: 'alert' });
      const next = h('button', { class: 'primary', type: 'button', text: '下一步：对比' });
      next.onclick = () => run(next, '正在对比……', error, async () => {
        if (!text.value.trim()) throw new Error('请先粘贴内容，或选择一个文件。');
        draft = text.value;
        const res = await call('/api/import/preview', { env: env.id, text: text.value });
        review(text.value, res);
      });
      mount(body,
        h('p', { text: '粘贴 .env 格式的内容（每行一个“名称=值”），或者选择文件。下一步会先列出新增和修改的变量，确认后才写入。' }),
        text, file, error,
        h('div', { class: 'actions' },
          h('button', { type: 'button', text: '选择文件', onclick: () => file.click() }),
          h('span', { class: 'grow' }),
          h('button', { type: 'button', text: '取消', onclick: finish }), next));
      setTimeout(() => text.focus());
    };

    const review = (text, { items, errors }) => {
      const list = diffList(items);
      const error = h('p', { class: 'error', role: 'alert' });
      const count = (s) => items.filter((i) => i.status === s).length;
      const apply = h('button', { class: 'primary', type: 'button', text: '导入所选', disabled: items.length === 0 });
      apply.onclick = () => run(apply, '正在导入……', error, async () => {
        const names = list.chosen();
        if (!names.length) throw new Error('没有勾选任何变量。');
        const { results } = await call('/api/import/apply', { env: env.id, text, names });
        done = true;
        const failed = failures(results);
        if (!failed.length) {
          toast(`已导入 ${results.length} 个变量到“${env.name}”。`);
          return finish();
        }
        for (const [name, box] of list.boxes) box.checked = failed.some((r) => r.name === name);
        mount(error, `${results.length - failed.length} 个已导入，${failed.length} 个没有成功（已为你勾选，可以再试一次）：`, failureList(failed));
      });
      mount(body,
        h('p', { text: `共识别出 ${items.length} 个变量：新增 ${count('new')} 个，修改 ${count('changed')} 个，不变 ${count('same')} 个。修改会覆盖现有的值。` }),
        errors.length > 0 && h('div', { class: 'warn' }, h('b', { text: `有 ${errors.length} 行没有识别，不会导入：` }),
          h('ul', { class: 'names' }, errors.map((e) => h('li', { text: `第 ${e.line} 行：${e.message}` })))),
        items.length > 0 && list.el,
        error,
        h('div', { class: 'actions' },
          h('button', { type: 'button', text: '上一步', onclick: input }),
          h('span', { class: 'grow' }),
          h('button', { type: 'button', text: '取消', onclick: finish }), apply));
    };

    input();
    return body;
  }, { wide: true });
}

export function copyDialog(env, names, envs) {
  return modal('复制到其他环境', (close) => {
    const body = h('div', { class: 'stack' });
    const others = envs.filter((e) => e.id !== env.id);
    const target = h('select', {}, others.map((e) => h('option', { value: e.id, text: e.name })));
    const slot = h('div', {});
    const error = h('p', { class: 'error', role: 'alert' });
    const apply = h('button', { class: 'primary', type: 'button', text: '复制所选', disabled: true });
    let list = null;
    const preview = async () => {
      apply.disabled = true;
      error.textContent = '';
      try {
        const { items } = await call('/api/copy/preview', { from: env.id, to: target.value, names });
        list = diffList(items);
        mount(slot, list.el);
        apply.disabled = items.length === 0;
      } catch (e) {
        mount(slot);
        error.textContent = e.message;
      }
    };
    target.onchange = preview;
    apply.onclick = () => run(apply, '正在复制……', error, async () => {
      const chosen = list.chosen();
      if (!chosen.length) throw new Error('没有勾选任何变量。');
      const to = others.find((e) => e.id === target.value);
      const { results } = await call('/api/copy/apply', { from: env.id, to: to.id, names: chosen });
      const failed = failures(results);
      if (failed.length) {
        mount(error, `${results.length - failed.length} 个已复制，${failed.length} 个没有成功：`, failureList(failed));
        return;
      }
      toast(`已把 ${results.length} 个变量复制到“${to.name}”。`);
      close(true);
    });
    mount(body,
      h('p', { text: `把“${env.name}”中选中的 ${names.length} 个变量复制到另一个环境。目标环境里同名的变量会被覆盖。` }),
      field('目标环境', target), slot, error,
      h('div', { class: 'actions' }, h('button', { type: 'button', text: '取消', onclick: () => close() }), apply));
    preview();
    return body;
  }, { wide: true });
}

export function settingsDialog(account, apply) {
  return modal('设置', (close) => {
    const oldIn = secretInput({ required: true, maxLength: 128 });
    const newIn = secretInput({ required: true, maxLength: 128 });
    const againIn = secretInput({ required: true, maxLength: 128 });
    const passError = h('p', { class: 'error', role: 'alert' });
    const save = h('button', { class: 'primary', type: 'submit', text: '修改口令' });
    const passForm = h('form', {
      class: 'stack',
      autocomplete: 'off',
      onsubmit: (ev) => {
        ev.preventDefault();
        if (newIn.value !== againIn.value) {
          passError.textContent = '两次输入的新口令不一样。';
          return;
        }
        run(save, '正在修改……', passError, async () => {
          await call('/api/passphrase', { old: oldIn.value, new: newIn.value });
          toast('管理口令已修改。');
          close();
        });
      },
    }, h('h3', { text: '修改管理口令' }), field('现在的口令', oldIn), field('新口令', newIn, RULE), field('再输入一次新口令', againIn), passError, h('div', { class: 'actions' }, save));

    const outIn = secretInput({ required: true, maxLength: 128 });
    const outError = h('p', { class: 'error', role: 'alert' });
    const out = h('button', { class: 'danger', type: 'submit', text: '退出管理登录' });
    const logout = async (confirmLast) => {
      try {
        apply(await call('/api/logout', { passphrase: outIn.value, confirmLast }));
        close();
      } catch (e) {
        if (e.code !== 'last_manager') throw e;
        const sure = await confirmBox('这是唯一的管理设备', [
          '这台电脑是账号里唯一的管理设备。退出后只能用恢复码找回账号。',
          '请确认恢复码在手边，再继续。',
        ], '仍然退出', { danger: true });
        if (sure) await logout(true);
      }
    };
    const outForm = h('form', {
      class: 'stack',
      autocomplete: 'off',
      onsubmit: (ev) => {
        ev.preventDefault();
        run(out, '正在退出……', outError, () => logout(false));
      },
    }, h('h3', { text: '退出管理登录' }),
      h('p', { class: 'mute', text: '从账号中移除这台电脑的管理身份，并删除这台电脑上的管理密钥。日常登录（harmonia login）不受影响。' }),
      field('管理口令', outIn), outError, h('div', { class: 'actions' }, out));

    return h('div', { class: 'stack' },
      h('p', { class: 'kv' },
        h('span', { text: '账号' }), h('b', { text: account.email }),
        h('span', { text: '服务器' }), h('b', { text: account.server }),
        h('span', { text: '设备名' }), h('b', { text: account.deviceName })),
      h('hr'), passForm, h('hr'), outForm);
  });
}
