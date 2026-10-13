// 配对码输错的递增等待（docs/protocol.md 3.8）：按“账号 + 网络”计数，攻击者输错只影响他自己的网络。
// 不作废配对码，也不锁定账号：合法用户最多等几分钟，或者不填配对码改用扫码。
import { one } from "./db";
import type { Deps } from "./context";
import { rateLimited } from "./util";

const WINDOW = 15 * 60_000;
/** 每个网络不受限制的输错次数。 */
const FREE = 5;
const FIRST_WAIT = 5_000;
const MAX_WAIT = 5 * 60_000;

/** 这个网络还在等待期时拒绝，并且不校验配对码。 */
export function checkWait(deps: Deps, net: string) {
  const row = one<{ next_at: number }>(deps.sql, `SELECT next_at FROM code_failures WHERE net = ?`, net);
  const now = deps.now();
  if (row && row.next_at > now) {
    const wait = row.next_at - now;
    throw rateLimited(`配对码输错次数过多，请 ${formatWait(wait)}后再试。也可以不填配对码，改用扫码。`, wait);
  }
}

/** 记录一次输错：超出免限制次数后，该网络的等待时间逐次翻倍。 */
export function recordFailure(deps: Deps, net: string) {
  const now = deps.now();
  const row = one<{ count: number; window_start: number }>(deps.sql, `SELECT * FROM code_failures WHERE net = ?`, net);
  const fresh = !row || now - row.window_start >= WINDOW;
  const count = fresh ? 1 : row.count + 1;
  const nextAt = count >= FREE ? now + Math.min(FIRST_WAIT * 2 ** (count - FREE), MAX_WAIT) : 0;
  deps.sql.run(
    `INSERT OR REPLACE INTO code_failures (net, count, window_start, next_at) VALUES (?, ?, ?, ?)`,
    net,
    count,
    fresh ? now : row.window_start,
    nextAt,
  );
}

/** 用配对码成功创建请求后，清除该网络的输错计数。 */
export function clearFailures(deps: Deps, net: string) {
  deps.sql.run(`DELETE FROM code_failures WHERE net = ?`, net);
}

/** 清理过期的计数和邮件记录（由 sweep 调用）。 */
export function sweepGuard(deps: Deps) {
  const now = deps.now();
  deps.sql.run(`DELETE FROM code_failures WHERE window_start <= ? AND next_at <= ?`, now - WINDOW, now);
  deps.sql.run(`DELETE FROM pairing_codes WHERE expires_at <= ?`, now);
  deps.sql.run(`DELETE FROM mail_log WHERE at <= ?`, now - 24 * 60 * 60_000);
  deps.sql.run(`DELETE FROM email_flows WHERE expires_at <= ?`, now);
}

function formatWait(ms: number): string {
  const s = Math.ceil(ms / 1000);
  return s < 60 ? `${s} 秒` : `${Math.ceil(s / 60)} 分钟`;
}
