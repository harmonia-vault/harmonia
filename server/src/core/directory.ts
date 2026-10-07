// 邮箱目录：邮箱 → 账号 ID 映射与注册策略（运行在目录 Durable Object 内）。
import { one, type Sql } from "./db";
import { networkId } from "./net";
import { ApiError, conflict, newId, randomB64 } from "./util";

export type Entry = { accountId: string; status: "pending" | "active" };

const PENDING_TTL = 15 * 60_000;

export class Directory {
  constructor(
    private sql: Sql,
    private now: () => number,
  ) {
    sql.run(`CREATE TABLE IF NOT EXISTS entries (
      email TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL, expires_at INTEGER NOT NULL)`);
    sql.run(`CREATE TABLE IF NOT EXISTS dir_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)`);
    sql.run(`CREATE TABLE IF NOT EXISTS dir_reset (email TEXT PRIMARY KEY)`);
    sql.run(`CREATE TABLE IF NOT EXISTS dir_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start INTEGER NOT NULL)`);
    sql.run(`CREATE TABLE IF NOT EXISTS dir_secret (id INTEGER PRIMARY KEY CHECK (id = 1), value TEXT NOT NULL)`);
  }

  firstCompleted(): boolean {
    return !!one<{ value: number }>(this.sql, `SELECT value FROM dir_meta WHERE key = 'first_completed'`)?.value;
  }

  /** 为注册预留账号 ID；邮箱处于待验证状态时复用原 ID。 */
  reserve(email: string, allowRegistration: boolean): string {
    return this.sql.transaction(() => {
      const e = one<{ account_id: string; status: string }>(this.sql, `SELECT * FROM entries WHERE email = ?`, email);
      if (e?.status === "active") throw conflict("这个邮箱已经注册，请直接登录。");
      // 重置过的账号保留重新注册的资格，即使实例已关闭注册。
      if (!allowRegistration && this.firstCompleted() && e?.status !== "reset") {
        throw new ApiError(403, "forbidden", "这台服务器没有开放注册。");
      }
      const accountId = e && e.status !== "reset" ? e.account_id : newId();
      this.sql.run(
        `INSERT OR REPLACE INTO entries (email, account_id, status, expires_at) VALUES (?, ?, 'pending', ?)`,
        email,
        accountId,
        this.now() + PENDING_TTL,
      );
      return accountId;
    });
  }

  /** 邮箱验证完成（或无需验证）后启用账号。 */
  activate(email: string, accountId: string, allowRegistration: boolean): void {
    this.sql.transaction(() => {
      const e = one<{ account_id: string; status: string }>(this.sql, `SELECT * FROM entries WHERE email = ?`, email);
      if (!e || e.account_id !== accountId) throw conflict("注册已失效，请重新注册。");
      if (e.status === "active") return;
      if (!allowRegistration && this.firstCompleted() && !this.wasReset(email)) {
        throw new ApiError(403, "forbidden", "这台服务器没有开放注册。");
      }
      this.sql.run(`UPDATE entries SET status = 'active', expires_at = 0 WHERE email = ?`, email);
      this.sql.run(`INSERT OR REPLACE INTO dir_meta (key, value) VALUES ('first_completed', 1)`);
    });
  }

  lookup(email: string): Entry | null {
    const e = one<{ account_id: string; status: string; expires_at: number }>(
      this.sql,
      `SELECT * FROM entries WHERE email = ?`,
      email,
    );
    if (!e || e.status === "reset") return null;
    if (e.status === "pending" && e.expires_at <= this.now()) return null;
    return { accountId: e.account_id, status: e.status as Entry["status"] };
  }

  /** 删除映射。reset=true 表示账号被用户重置：邮箱保留重新注册的资格。 */
  remove(email: string, accountId: string, reset = false): void {
    if (reset) {
      this.sql.run(`UPDATE entries SET status = 'reset', expires_at = 0 WHERE email = ? AND account_id = ?`, email, accountId);
      this.sql.run(`INSERT OR IGNORE INTO dir_reset (email) VALUES (?)`, email);
    } else {
      this.sql.run(`DELETE FROM entries WHERE email = ? AND account_id = ?`, email, accountId);
    }
  }

  private wasReset(email: string): boolean {
    return this.sql.all(`SELECT 1 FROM dir_reset WHERE email = ?`, email).length > 0;
  }

  /**
   * 按网络的固定窗口限流（docs/protocol.md 3.8）。ip 为空时只按 bucket 计数（整个实例共用）。
   * 只保存网络标识的 HMAC。允许时返回 0，否则返回到窗口结束还要等多少毫秒。
   */
  async limit(bucket: string, ip: string | null, max: number, windowMs: number): Promise<number> {
    const key = ip === null ? bucket : `${bucket}:${await networkId(this.secret(), ip)}`;
    const now = this.now();
    const row = one<{ count: number; window_start: number }>(this.sql, `SELECT * FROM dir_limits WHERE key = ?`, key);
    if (!row || now - row.window_start > windowMs) {
      this.sql.run(`INSERT OR REPLACE INTO dir_limits (key, count, window_start) VALUES (?, 1, ?)`, key, now);
      this.sql.run(`DELETE FROM dir_limits WHERE window_start <= ?`, now - 24 * 60 * 60_000);
      return 0;
    }
    if (row.count >= max) return row.window_start + windowMs - now;
    this.sql.run(`UPDATE dir_limits SET count = count + 1 WHERE key = ?`, key);
    return 0;
  }

  private secret(): string {
    const row = one<{ value: string }>(this.sql, `SELECT value FROM dir_secret WHERE id = 1`);
    if (row) return row.value;
    const value = randomB64(32);
    this.sql.run(`INSERT INTO dir_secret (id, value) VALUES (1, ?)`, value);
    return value;
  }
}
