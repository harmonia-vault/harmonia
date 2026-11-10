// 登记、句柄与限流（docs/protocol.md 5.1、5.3、5.4）。只保存句柄的 SHA-256。
import { one, type Sql } from "./db";
import type { NotifyType } from "./messages";
import { bad, notFound, randomB64, rateLimited, sha256 } from "./util";

export type Platform = "ios" | "android";
export type ApnsEnv = "production" | "sandbox";
export type Registration = { platform: Platform; token: string; apnsEnv: ApnsEnv | null };

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

export const LIMITS = {
  /** 同一个句柄、同一种类型，这段时间内最多发出一条，其余合并。 */
  mergeMs: 10_000,
  perHandleDay: 1000,
  registerPerMinute: 20,
  registerPerDay: 200,
  defaultGlobalPerMinute: 1000,
  /** 最近一次登记或确认超过这个时间的登记删除。 */
  idleMs: 90 * DAY,
};

/** 解析登记内容：平台、推送令牌和 APNs 环境。 */
export function parseRegistration(body: Record<string, unknown>, platform: unknown): Registration {
  if (platform !== "ios" && platform !== "android") throw bad("platform 只能是 ios 或 android。");
  const token = body.token;
  if (typeof token !== "string" || token.length === 0 || token.length > 4096) throw bad("推送令牌格式不对。");
  if (platform === "ios") {
    if (!/^[0-9a-fA-F]{32,200}$/.test(token)) throw bad("推送令牌格式不对。");
    const env = body.apnsEnvironment;
    if (env !== "production" && env !== "sandbox") throw bad("apnsEnvironment 只能是 production 或 sandbox。");
    return { platform, token: token.toLowerCase(), apnsEnv: env };
  }
  if (!/^[A-Za-z0-9_:.-]+$/.test(token)) throw bad("推送令牌格式不对。");
  return { platform, token, apnsEnv: null };
}

type Row = { handle_hash: string; platform: Platform; token: string; apns_env: ApnsEnv | null };

export class Registry {
  constructor(
    private sql: Sql,
    private now: () => number,
    private globalPerMinute = LIMITS.defaultGlobalPerMinute,
  ) {}

  /** 新登记，返回句柄。net 是请求方网络的标识，用于限流。 */
  async register(reg: Registration, net: string): Promise<string> {
    this.sweep();
    const wait =
      this.wait(`register-min:${net}`, MINUTE, LIMITS.registerPerMinute) ||
      this.wait(`register-day:${net}`, DAY, LIMITS.registerPerDay);
    if (wait) throw rateLimited("登记太频繁，请稍后再试。", wait);
    const handle = randomB64(32);
    const now = this.now();
    const hash = await sha256(handle);
    this.sql.transaction(() => {
      this.add(`register-min:${net}`, MINUTE);
      this.add(`register-day:${net}`, DAY);
      this.sql.run(
        `INSERT INTO registrations (handle_hash, platform, token, apns_env, created_at, refreshed_at) VALUES (?, ?, ?, ?, ?, ?)`,
        hash,
        reg.platform,
        reg.token,
        reg.apnsEnv,
        now,
        now,
      );
    });
    return handle;
  }

  /** 确认登记：更新令牌和最近确认时间，句柄不变。平台不能改。 */
  async confirm(handle: string, body: Record<string, unknown>): Promise<void> {
    const row = await this.find(handle);
    const reg = parseRegistration(body, row.platform);
    this.sql.run(
      `UPDATE registrations SET token = ?, apns_env = ?, refreshed_at = ? WHERE handle_hash = ?`,
      reg.token,
      reg.apnsEnv,
      this.now(),
      row.handle_hash,
    );
  }

  async remove(handle: string): Promise<void> {
    this.sql.run(`DELETE FROM registrations WHERE handle_hash = ?`, await sha256(handle));
  }

  /**
   * 准备发一条通知：句柄不存在时抛 not_found；10 秒内已经发过同一类时返回 null（合并，不发送）；
   * 超出每天或全局上限时抛 rate_limited。允许发送时计入各项计数。
   */
  async claim(handle: string, type: NotifyType): Promise<{ hash: string; reg: Registration } | null> {
    const row = await this.find(handle);
    const merge = `last:${row.handle_hash}:${type}`;
    if (this.wait(merge, LIMITS.mergeMs, 1)) return null;
    const day = `day:${row.handle_hash}`;
    const wait = this.wait(day, DAY, LIMITS.perHandleDay) || this.wait("global", MINUTE, this.globalPerMinute);
    if (wait) throw rateLimited("通知太多，这次没有发送。", wait);
    this.sql.transaction(() => {
      this.add(merge, LIMITS.mergeMs);
      this.add(day, DAY);
      this.add("global", MINUTE);
    });
    return { hash: row.handle_hash, reg: { platform: row.platform, token: row.token, apnsEnv: row.apns_env } };
  }

  /** 推送令牌被 APNs / FCM 判定失效：删除这条登记。 */
  forget(hash: string): void {
    this.sql.run(`DELETE FROM registrations WHERE handle_hash = ?`, hash);
  }

  /** 每小时最多一次：删除久未确认的登记和过期的计数。 */
  sweep(): void {
    const now = this.now();
    const last = Number(one<{ value: string }>(this.sql, `SELECT value FROM kv WHERE key = 'swept_at'`)?.value ?? 0);
    if (now - last < 60 * MINUTE) return;
    this.sql.transaction(() => {
      this.sql.run(`DELETE FROM registrations WHERE refreshed_at < ?`, now - LIMITS.idleMs);
      this.sql.run(`DELETE FROM counters WHERE window_start < ?`, now - DAY);
      this.sql.run(`INSERT OR REPLACE INTO kv (key, value) VALUES ('swept_at', ?)`, String(now));
    });
  }

  private async find(handle: string): Promise<Row> {
    const row = one<Row>(this.sql, `SELECT * FROM registrations WHERE handle_hash = ?`, await sha256(handle));
    if (!row) throw notFound("没有这个登记，请重新登记。");
    return row;
  }

  /** 固定窗口计数：已达上限时返回还要等的毫秒数，否则返回 0。只读。 */
  private wait(key: string, windowMs: number, max: number): number {
    const row = one<{ count: number; window_start: number }>(this.sql, `SELECT * FROM counters WHERE key = ?`, key);
    const now = this.now();
    if (!row || now - row.window_start >= windowMs || row.count < max) return 0;
    return row.window_start + windowMs - now;
  }

  private add(key: string, windowMs: number): void {
    const now = this.now();
    const row = one<{ window_start: number }>(this.sql, `SELECT window_start FROM counters WHERE key = ?`, key);
    if (!row || now - row.window_start >= windowMs) {
      this.sql.run(`INSERT OR REPLACE INTO counters (key, count, window_start) VALUES (?, 1, ?)`, key, now);
    } else {
      this.sql.run(`UPDATE counters SET count = count + 1 WHERE key = ?`, key);
    }
  }
}
