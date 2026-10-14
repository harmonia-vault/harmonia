// 与本机 harmonia 进程通信。会话令牌只放在这个标签页的会话存储里，通过请求头发送。

const KEY = 'harmonia-manager-token';
let token = '';
try {
  token = sessionStorage.getItem(KEY) || '';
} catch {
  // 会话存储不可用时，令牌只留在内存里，刷新页面后需要重新运行 harmonia manager。
}

let onFatal = () => {};
let pace = 5000; // 查询状态的间隔（毫秒）
let active = true;
let lastInput = Date.now();

// idleFor 返回距离上一次操作过去了多少毫秒，用来显示还有多久自动锁定。
export const idleFor = () => Date.now() - lastInput;

export class ApiError extends Error {
  constructor(code, message, fatal = false) {
    super(message);
    this.code = code;
    this.fatal = fatal;
  }
}

async function request(method, path, body, auth = true) {
  let res;
  try {
    res = await fetch(path, {
      method,
      headers: { ...(auth ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
    });
  } catch {
    const e = new ApiError('offline', 'harmonia manager 已经结束，或者与它的连接断开了。请回到终端重新运行 harmonia manager。', true);
    onFatal(e);
    throw e;
  }
  let data = null;
  try {
    data = await res.json();
  } catch {
    // 不是 JSON 的响应按失败处理。
  }
  if (res.ok && data) return data;
  const e = new ApiError(data?.error || 'failed', data?.message || `操作没有成功（${res.status}）。`, data?.error === 'session');
  if (e.fatal) onFatal(e);
  throw e;
}

export const call = (path, body = {}) => request('POST', path, body);
export const getState = () => request('GET', '/api/state');

// start 用地址里 # 后面的一次性访问码换取会话令牌，并把访问码从地址栏去掉。
export async function start(fatal) {
  onFatal = fatal;
  const code = location.hash.slice(1);
  if (code) {
    history.replaceState(null, '', location.pathname);
    try {
      token = (await request('POST', '/api/session', { code }, false)).token;
      try {
        sessionStorage.setItem(KEY, token);
      } catch {
        // 见上。
      }
    } catch (e) {
      if (!token) throw e;
    }
  }
  if (!token) {
    const e = new ApiError('session', '这个页面需要从终端打开：请运行 harmonia manager，使用它打开的页面。', true);
    onFatal(e);
    throw e;
  }
}

// watch 每 5 秒向 harmonia 报告页面还开着（以及这段时间有没有操作），并把最新状态交给 onState。
export function watch(onState) {
  for (const ev of ['pointerdown', 'keydown', 'input', 'wheel', 'touchstart']) {
    addEventListener(ev, () => {
      active = true;
      lastInput = Date.now();
    }, { passive: true, capture: true });
  }
  let stopped = false;
  const tick = async () => {
    if (stopped) return;
    const was = active;
    active = false;
    try {
      onState(await call('/api/ping', { active: was }));
    } catch (e) {
      if (e.fatal) stopped = true;
    }
    if (!stopped) setTimeout(tick, pace);
  };
  setTimeout(tick, pace);
}

// setPace 调整查询状态的间隔：等待手机批准时查得更勤。
export function setPace(ms) {
  pace = ms;
}
