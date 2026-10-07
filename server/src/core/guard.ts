// 密码登录的风控（docs/protocol.md 3.8）：失败按“账号 + 网络”计数，攻击者的失败只影响他自己的网络；
// 失败多了进入受攻击状态，期间配置了发信就要求邮件验证码，否则收紧每个网络的免限制次数。不锁定账号。
import { one } from "./db";
import type { Deps } from "./context";
import { rateLimited } from "./util";

const WINDOW = 15 * 60_000;
const ATTACK_THRESHOLD = 20;
const ATTACK_QUIET = 60 * 60_000;
const FIRST_WAIT = 5_000;
const MAX_WAIT = 5 * 60_000;

/** 是否处于受攻击状态：进入后，连续 1 小时没有失败才退出。 */
export function underAttack(deps: Deps): boolean {
  if (!one(deps.sql, `SELECT 1 FROM kv WHERE key = 'login_attack'`)) return false;
  const last = one<{ at: number | null }>(deps.sql, `SELECT MAX(at) AS at FROM login_events`)?.at ?? 0;
  if (deps.now() - last < ATTACK_QUIET) return true;
  deps.sql.run(`DELETE FROM kv WHERE key = 'login_attack'`);
  return false;
}

/** 这个网络还在等待期时拒绝，并且不校验密码。 */
export function checkWait(deps: Deps, net: string) {
  const row = one<{ next_at: number }>(deps.sql, `SELECT next_at FROM login_failures WHERE net = ?`, net);
  const now = deps.now();
  if (row && row.next_at > now) {
    const wait = row.next_at - now;
    throw rateLimited(
      `尝试次数过多，请 ${formatWait(wait)}后再试。如果不是你本人在尝试，请在管理设备上修改密码。`,
      wait,
    );
  }
}

/** 记录一次密码错误：超出免限制次数后，该网络的等待时间逐次翻倍；全部网络的失败累计到阈值时进入受攻击状态。 */
export function recordFailure(deps: Deps, net: string, attack: boolean) {
  const now = deps.now();
  const row = one<{ count: number; window_start: number }>(deps.sql, `SELECT * FROM login_failures WHERE net = ?`, net);
  const count = row && now - row.window_start < WINDOW ? row.count + 1 : 1;
  const free = attack ? 1 : 5;
  const nextAt = count >= free ? now + Math.min(FIRST_WAIT * 2 ** (count - free), MAX_WAIT) : 0;
  deps.sql.run(
    `INSERT OR REPLACE INTO login_failures (net, count, window_start, next_at) VALUES (?, ?, ?, ?)`,
    net,
    count,
    count === 1 ? now : row!.window_start,
    nextAt,
  );
  deps.sql.run(`INSERT INTO login_events (at) VALUES (?)`, now);
  const recent = one<{ n: number }>(deps.sql, `SELECT COUNT(*) AS n FROM login_events WHERE at > ?`, now - WINDOW)!.n;
  if (recent >= ATTACK_THRESHOLD) deps.sql.run(`INSERT OR REPLACE INTO kv (key, value) VALUES ('login_attack', '1')`);
}

/** 登录成功：清除该网络的失败计数。 */
export function clearFailures(deps: Deps, net: string) {
  deps.sql.run(`DELETE FROM login_failures WHERE net = ?`, net);
}

/** 修改密码后，攻击者手里的密码已经失效：退出受攻击状态并清空计数。 */
export function resetGuard(deps: Deps) {
  deps.sql.run(`DELETE FROM kv WHERE key = 'login_attack'`);
  deps.sql.run(`DELETE FROM login_failures`);
  deps.sql.run(`DELETE FROM login_events`);
}

/** 清理过期的计数（由 sweep 调用）。 */
export function sweepGuard(deps: Deps) {
  const now = deps.now();
  deps.sql.run(`DELETE FROM login_failures WHERE window_start <= ? AND next_at <= ?`, now - WINDOW, now);
  deps.sql.run(`DELETE FROM login_events WHERE at <= ?`, now - ATTACK_QUIET);
  deps.sql.run(`DELETE FROM mail_log WHERE at <= ?`, now - 24 * 60 * 60_000);
  deps.sql.run(`DELETE FROM email_flows WHERE expires_at <= ?`, now);
}

function formatWait(ms: number): string {
  const s = Math.ceil(ms / 1000);
  return s < 60 ? `${s} 秒` : `${Math.ceil(s / 60)} 分钟`;
}
