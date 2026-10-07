// 请求上下文：依赖注入、会话解析与权限判断。
import type { Context } from "hono";
import { one, type Sql } from "./db";
import type { Mailer } from "./email";
import { sweepGuard } from "./guard";
import { networkId } from "./net";
import { ApiError, b64, forbidden, obj, randomB64, rateLimited, sha256, unauthorized, type Role } from "./util";

export type PushMessage = { type: "changed"; seq: number } | { type: "pairing" } | { type: "revoked" };
export type PushTarget = "all" | "managers" | { device: string };

export interface Notifier {
  send(target: PushTarget, msg: PushMessage): void;
  /** 断开某台设备的全部推送连接。 */
  disconnect(deviceId: string): void;
}

/** 发给配对发起方的最终结果。 */
export type PairingResult = "approved" | "rejected" | "expired";

/** 配对发起方的等待连接（docs/protocol.md 3.5.1）。 */
export interface PairingWaiters {
  accept(pairingId: string): Response;
  /** 发起方是否仍保持等待连接。 */
  waiting(pairingId: string): boolean;
  /** 全部等待连接，以及最近一次收到心跳（或建立连接）的时间。 */
  list(): { pairingId: string; seenAt: number }[];
  /** 把结果发给发起方（可省略）并关闭连接。 */
  close(pairingId: string, result?: PairingResult): void;
}

export interface Deps {
  sql: Sql;
  notifier: Notifier;
  waiters: PairingWaiters;
  mailer: Mailer;
  now(): number;
  /** 接受一条推送连接（仅 Durable Object 环境提供）。 */
  acceptSocket?(device: Device): Response;
}

export type Device = {
  id: string;
  name: string;
  platform: string;
  kind: "manager" | "client";
  sign_pub: string;
  box_pub: string;
  cert: string;
  root_sealed: string | null;
  status: string;
  rotation_required: number;
  created_at: number;
  last_seen_at: number;
};

export type Account = {
  account_id: string;
  email: string;
  status: "pending" | "active";
  kdf_salt: string;
  auth_salt: string;
  auth_hash: string;
  root_pub: string | null;
  recovery_generation: number | null;
  recovery_sign_pub: string | null;
  recovery_box_pub: string | null;
  root_recovery_sealed: string | null;
  root_recovery_sig: string | null;
};

/** 已完成初始化的账号（root 与恢复信息齐全）。 */
export type InitializedAccount = Account & {
  root_pub: string;
  recovery_generation: number;
  recovery_sign_pub: string;
  recovery_box_pub: string;
  root_recovery_sealed: string;
  root_recovery_sig: string;
};

export const SESSION_TTL = { password: 15 * 60_000, device: 60 * 60_000, recovery: 15 * 60_000 } as const;
export type SessionKind = keyof typeof SESSION_TTL;

export async function readJson(c: Context): Promise<Record<string, unknown>> {
  const text = await c.req.text();
  if (text.length > 2_000_000) throw new ApiError(413, "invalid_request", "请求内容过大。");
  try {
    return obj(JSON.parse(text));
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(400, "invalid_request", "请求内容不是有效的 JSON。");
  }
}

export function account(sql: Sql): Account | undefined {
  return one<Account>(sql, `SELECT * FROM account WHERE id = 1`);
}

export function requireAccount(sql: Sql): Account {
  const a = account(sql);
  if (!a) throw new ApiError(404, "not_found", "这个账号不存在。");
  return a;
}

export function requireInitialized(sql: Sql): InitializedAccount {
  const a = requireAccount(sql);
  if (!a.root_pub) throw new ApiError(409, "conflict", "账号还没有在手机上完成初始化。");
  return a as InitializedAccount;
}

export async function tokenHash(token: string): Promise<string> {
  return b64(await sha256(token));
}

export async function createSession(deps: Deps, kind: SessionKind, deviceId: string | null) {
  const token = `${requireAccount(deps.sql).account_id}.${b64(crypto.getRandomValues(new Uint8Array(32)))}`;
  const expiresAt = deps.now() + SESSION_TTL[kind];
  deps.sql.run(
    `INSERT INTO sessions (token_hash, kind, device_id, expires_at) VALUES (?, ?, ?, ?)`,
    await tokenHash(token),
    kind,
    deviceId,
    expiresAt,
  );
  return { token, expiresAt };
}

export type Session = { kind: SessionKind; deviceId: string | null; tokenHash: string };

export async function session(c: Context, deps: Deps): Promise<Session> {
  const m = /^Bearer ([A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})$/.exec(c.req.header("authorization") ?? "");
  if (!m) throw unauthorized("请先登录。");
  const hash = await tokenHash(m[1]!);
  const row = one<{ kind: SessionKind; device_id: string | null }>(
    deps.sql,
    `SELECT kind, device_id FROM sessions WHERE token_hash = ? AND expires_at > ?`,
    hash,
    deps.now(),
  );
  if (!row) throw unauthorized();
  return { kind: row.kind, deviceId: row.device_id, tokenHash: hash };
}

export function deviceById(sql: Sql, id: string): Device | undefined {
  return one<Device>(sql, `SELECT * FROM devices WHERE id = ?`, id);
}

/** 当前设备；会话失效或设备被撤销时抛错。 */
export async function requireDevice(
  c: Context,
  deps: Deps,
  opts: { manager?: boolean; allowRotation?: boolean } = {},
): Promise<Device> {
  const s = await session(c, deps);
  if (s.kind !== "device" || !s.deviceId) throw unauthorized();
  const d = deviceById(deps.sql, s.deviceId);
  if (!d) throw unauthorized();
  if (d.status !== "active") throw new ApiError(401, "device_revoked", "这台设备已被移除，请重新连接。");
  if (opts.manager && d.kind !== "manager") throw forbidden("只有管理设备可以执行此操作。");
  if (d.rotation_required && !opts.allowRotation) {
    throw new ApiError(403, "rotation_required", "请先完成恢复码更换。");
  }
  return d;
}

/** 设备在某环境的当前有效权限；管理设备恒为 admin。 */
export function envRole(deps: Deps, d: Device, envId: string): Role | null {
  if (d.kind === "manager") return "admin";
  const g = one<{ role: Role }>(
    deps.sql,
    `SELECT role FROM grants WHERE device_id = ? AND env_id = ? AND (expires_at = 0 OR expires_at > ?)`,
    d.id,
    envId,
    deps.now(),
  );
  return g?.role ?? null;
}

export function activeManagers(sql: Sql): Device[] {
  return sql.all<Device>(`SELECT * FROM devices WHERE kind = 'manager' AND status = 'active'`);
}

/** 请求方 IP；本地开发时没有该请求头。 */
export const clientIp = (c: Context) => c.req.header("cf-connecting-ip") ?? "local";

/** 账号内计算网络标识用的密钥，首次使用时随机生成（docs/protocol.md 3.8）。 */
function networkSecret(sql: Sql): string {
  const row = one<{ value: string }>(sql, `SELECT value FROM kv WHERE key = 'network_secret'`);
  if (row) return row.value;
  const secret = randomB64(32);
  sql.run(`INSERT INTO kv (key, value) VALUES ('network_secret', ?)`, secret);
  return secret;
}

/** 请求方所在网络的标识（只保存 HMAC）。wide 时 IPv6 按 /48 计。 */
export const requesterNet = (c: Context, deps: Deps, wide = false) => networkId(networkSecret(deps.sql), clientIp(c), wide);

/** 按网络的固定窗口限流（每分钟）。 */
export async function rateLimit(c: Context, deps: Deps, bucket: string, max: number) {
  const key = `${bucket}:${await requesterNet(c, deps)}`;
  const now = deps.now();
  const row = one<{ count: number; window_start: number }>(deps.sql, `SELECT * FROM rate_limits WHERE key = ?`, key);
  if (!row || now - row.window_start > 60_000) {
    deps.sql.run(`INSERT OR REPLACE INTO rate_limits (key, count, window_start) VALUES (?, 1, ?)`, key, now);
    return;
  }
  if (row.count >= max) throw rateLimited("操作太频繁，请稍后再试。", row.window_start + 60_000 - now);
  deps.sql.run(`UPDATE rate_limits SET count = count + 1 WHERE key = ?`, key);
}

/** 清理过期的会话、挑战、配对请求与配对阻止记录。 */
export function sweep(deps: Deps) {
  const now = deps.now();
  deps.sql.run(`DELETE FROM sessions WHERE expires_at <= ?`, now);
  deps.sql.run(`DELETE FROM challenges WHERE expires_at <= ?`, now);
  deps.sql.run(`UPDATE pairings SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?`, now);
  deps.sql.run(`DELETE FROM pairings WHERE expires_at <= ?`, now - 24 * 60 * 60_000);
  deps.sql.run(`DELETE FROM pairing_blocks WHERE until <= ?`, now);
  deps.sql.run(`DELETE FROM rate_limits WHERE window_start <= ?`, now - 60_000);
  deps.sql.run(`DELETE FROM idempotency WHERE created_at <= ?`, now - 7 * 24 * 60 * 60_000);
  sweepGuard(deps);
}
