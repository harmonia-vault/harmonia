// 还没有解锁时的界面：管理登录、等待手机批准、输入口令。左边说明它是怎么工作的，右边是要填的内容。
import { call } from './api.js';
import { brand, field, glyph, h, run, secretInput } from './dom.js';

export const RULE = '至少 8 个字符，包含大写字母、小写字母、数字、符号中的至少两类；不能是常见口令。';
const EXT = '有权读取网页内容的浏览器扩展能看到这里输入的口令和显示出来的变量值，请在没有不可信扩展的浏览器里使用。不要让浏览器保存这个口令。';

const POINTS = [
  ['laptop', '密钥留在这台电脑', '管理密钥用你的口令加密后保存在本机。加解密都在 harmonia 进程里完成，浏览器只负责显示。'],
  ['phone', '由手机批准', '管理登录要在手机上核对并批准。之后在手机的“设备”页随时可以移除这台电脑。'],
  ['server', '服务器只有密文', '这个页面由你电脑上的 harmonia 提供，不是服务器发来的。服务器看不到变量的值。'],
];

// gate 是未解锁界面的两栏布局。
function gate(title, lead, panel) {
  return h('main', { class: 'gate' },
    h('div', { class: 'intro' }, brand(),
      h('h1', { text: title }),
      h('p', { class: 'lead', text: lead }),
      h('ul', { class: 'points' }, POINTS.map(([g, t, d]) => h('li', {}, glyph(g, 52), h('div', {}, h('b', { text: t }), h('p', { text: d })))))),
    panel);
}

export function loginView(st, apply) {
  const a = st.account;
  const server = h('input', { type: 'url', value: a.server, placeholder: 'https://vault.example.com', required: true, spellcheck: false });
  const email = h('input', { type: 'email', value: a.email, placeholder: 'you@example.com', required: true, spellcheck: false });
  const name = h('input', { type: 'text', value: a.deviceName, maxLength: 64, required: true });
  const pass = secretInput({ required: true, maxLength: 128 });
  const again = secretInput({ required: true, maxLength: 128 });
  const code = h('input', { type: 'text', placeholder: '留空则用手机扫码', autocomplete: 'off', spellcheck: false, class: 'mono' });
  const agree = h('input', { type: 'checkbox', required: true });
  const error = h('p', { class: 'error', role: 'alert' });
  const submit = h('button', { class: 'primary big', type: 'submit', text: '开始管理登录' });
  const form = h('form', {
    class: 'card stack',
    autocomplete: 'off',
    onsubmit: (ev) => {
      ev.preventDefault();
      if (pass.value !== again.value) {
        error.textContent = '两次输入的口令不一样。';
        again.focus();
        return;
      }
      run(submit, '正在检查并发起请求……', error, async () => {
        apply(await call('/api/login', {
          server: server.value, email: email.value, deviceName: name.value, pairingCode: code.value, passphrase: pass.value,
        }));
      });
    },
  },
    h('h2', { text: '管理登录' }),
    a.fixed
      ? h('p', { class: 'kv' }, h('span', { text: '账号' }), h('b', { text: a.email }), h('span', { text: '服务器' }), h('b', { text: a.server }))
      : h('div', { class: 'pair-fields' }, field('服务器地址', server), field('邮箱', email)),
    field('设备名', name, '手机上会显示这个名字，用来和这台电脑的日常登录区分。'),
    h('div', { class: 'pair-fields' }, field('设置管理口令', pass), field('再输入一次', again)),
    h('p', { class: 'hint', text: `${RULE}每次打开管理页面都要输入它；忘记后只能退出管理登录，再重新登录。` }),
    field('配对码（可选）', code, '在手机“设备 → 添加设备 → 生成配对码”中获取；填写后手机会直接弹出批准页。'),
    h('p', { class: 'warn', text: '请只在自己日常使用的电脑上开启，不要在多人共用的机器或运行 AI 助手的服务器上开启。' }),
    h('label', { class: 'check' }, agree, h('span', { text: '我了解：这台电脑将能读取和修改账号里的全部环境。' })),
    error,
    submit,
    h('p', { class: 'mute small', text: EXT }));
  return {
    el: gate('让这台电脑成为管理设备', '管理登录之后，可以在这里批量管理全部环境和变量。它与日常登录（harmonia login）各自独立，互不影响。', form),
    focus: () => (a.fixed ? name : server).focus(),
  };
}

export function pairingView(st, apply) {
  const p = st.pairing;
  const left = h('b', { class: 'mono' });
  const tick = () => {
    const s = Math.max(0, Math.round((p.expiresAt - Date.now()) / 1000));
    left.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  };
  tick();
  const timer = setInterval(tick, 1000);
  const cancel = h('button', { type: 'button', text: '取消这次登录' });
  cancel.onclick = () => run(cancel, '正在取消……', null, async () => apply(await call('/api/login/cancel')));
  const panel = h('section', { class: 'card stack' },
    h('h2', { text: '在手机上批准' }),
    h('p', { text: p.authorized
      ? '已用配对码发起请求。手机上的 Harmonia 在前台时会直接弹出批准页，也可以在“设备”页的待批准列表中找到它。'
      : '在手机上打开 Harmonia，进入“设备 → 添加设备 → 扫码确认”，扫描二维码；无法扫码时选择“输入核对码”。' }),
    h('div', { class: 'pairing' },
      h('img', { class: 'qr', alt: '配对二维码', width: 188, height: 188, src: `data:image/svg+xml;utf8,${encodeURIComponent(p.qr)}` }),
      h('dl', {},
        h('dt', { text: '核对码' }), h('dd', { class: 'code mono', text: p.code }),
        h('dt', { text: '设备名' }), h('dd', { text: p.deviceName }),
        h('dt', { text: '剩余时间' }), h('dd', {}, left))),
    h('p', { class: 'warn', text: '批准前请核对手机上显示的核对码和设备名与这里一致，并保持“作为管理设备”开启。' }),
    h('div', { class: 'waiting' }, h('span', { class: 'pulse', 'aria-hidden': 'true' }), h('span', { text: '正在等待批准。关闭这个页面或结束 harmonia manager，这次请求就会作废。' })),
    cancel);
  return { el: gate('就差手机上点一下', '管理口令已经设置好。现在请在手机上核对并批准，这台电脑才会成为管理设备。', panel), dispose: () => clearInterval(timer) };
}

export function lockedView(st, apply) {
  const a = st.account;
  const pass = secretInput({ required: true, maxLength: 128, 'aria-label': '管理口令' });
  const error = h('p', { class: 'error', role: 'alert' });
  const submit = h('button', { class: 'primary big', type: 'submit', text: '解锁' });
  const form = h('form', {
    class: 'card stack',
    autocomplete: 'off',
    onsubmit: (ev) => {
      ev.preventDefault();
      run(submit, '正在解锁……', error, async () => {
        try {
          apply(await call('/api/unlock', { passphrase: pass.value }));
        } catch (e) {
          pass.select();
          throw e;
        }
      });
    },
  },
    h('h2', { text: '输入管理口令' }),
    h('p', { class: 'kv' },
      h('span', { text: '账号' }), h('b', { text: a.email }),
      h('span', { text: '设备名' }), h('b', { text: a.deviceName }),
      h('span', { text: '服务器' }), h('b', { text: a.server })),
    field('管理口令', pass),
    error,
    submit,
    h('details', {}, h('summary', { text: '忘记口令？' }),
      h('p', { class: 'mute', text: '口令无法找回。在终端运行 harmonia manager logout，询问口令时直接回车，删除这台电脑上的管理密钥；再到手机的“设备”页移除这台电脑的管理身份，然后重新管理登录。' })),
    h('p', { class: 'mute small', text: EXT }));
  return { el: gate('已锁定', '输入管理口令解开这台电脑上的管理密钥。5 分钟没有操作、关闭页面或结束 harmonia manager，都会重新锁定。', form), focus: () => pass.focus() };
}

export function brokenView(st) {
  return { el: h('main', { class: 'gate solo' }, h('section', { class: 'card stack' }, brand(), h('h1', { text: '管理登录数据已损坏' }), h('p', { text: st.notice || '请在终端运行 harmonia manager logout 后重新管理登录。' }))) };
}
