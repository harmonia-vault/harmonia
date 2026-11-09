// 授权与可见范围：设备被授权了哪些环境、能在本机解密哪些变量库和变量、能写哪些变量，
// 以及开启本机解密的授权需要哪些封装（docs/protocol.md 3.2、3.4，设计文档 17.2）。
import type { Sql } from "./db";
import type { Device } from "./context";
import type { Envelope } from "./keys";
import { insertEnvelopes, checkKeyVersions } from "./keys";
import { covers, type Ref } from "./refs";
import { bad, type Role } from "./util";

export type EnvRow = { id: string; name: string; refs: string; created_at: number };

export type GrantedEnv = {
  id: string;
  name: string;
  refs: Ref[];
  role: Role;
  expires_at: number;
  local_decrypt: number;
  active: number;
  position: number;
  grant_seq: number;
};

export const parseStoredRefs = (raw: string): Ref[] => JSON.parse(raw) as Ref[];

/** 全部变量库里现存（未删除）的变量名，按变量库分组。 */
export function vaultNames(sql: Sql): (vaultId: string) => string[] {
  const map = new Map<string, string[]>();
  for (const r of sql.all<{ vault_id: string; name: string }>(`SELECT vault_id, name FROM variables WHERE deleted = 0`)) {
    const list = map.get(r.vault_id);
    if (list) list.push(r.name);
    else map.set(r.vault_id, [r.name]);
  }
  return (vaultId) => map.get(vaultId) ?? [];
}

/** 设备当前被授权且未到期的环境，按激活顺序排列；管理设备可访问全部环境，恒为激活并可以本机解密。 */
export function grantedEnvs(sql: Sql, d: Device, now: number): GrantedEnv[] {
  if (d.kind === "manager") {
    return sql.all<EnvRow>(`SELECT id, name, refs, created_at FROM environments ORDER BY created_at`).map((e, i) => ({
      id: e.id,
      name: e.name,
      refs: parseStoredRefs(e.refs),
      role: "rw" as Role,
      expires_at: 0,
      local_decrypt: 1,
      active: 1,
      position: i,
      grant_seq: 0,
    }));
  }
  return sql
    .all<Omit<GrantedEnv, "refs"> & { refs: string }>(
      `SELECT e.id, e.name, e.refs, g.role, g.expires_at, g.local_decrypt, g.active, g.position, g.seq AS grant_seq
       FROM grants g JOIN environments e ON e.id = g.environment_id
       WHERE g.device_id = ? AND (g.expires_at = 0 OR g.expires_at > ?) ORDER BY g.position`,
      d.id,
      now,
    )
    .map((e) => ({ ...e, refs: parseStoredRefs(e.refs) }));
}

/**
 * 设备可以在本机解密的变量：返回变量库 ID → 覆盖它的引用。管理设备返回 null，表示全部。
 * 只算未到期、开启了本机解密的授权。
 */
export function localRefs(sql: Sql, d: Device, now: number): Map<string, Ref[]> | null {
  if (d.kind === "manager") return null;
  const out = new Map<string, Ref[]>();
  for (const env of grantedEnvs(sql, d, now)) {
    if (!env.local_decrypt) continue;
    for (const ref of env.refs) {
      const list = out.get(ref.vaultId);
      if (list) list.push(ref);
      else out.set(ref.vaultId, [ref]);
    }
  }
  return out;
}

/** 某变量是否在本机解密的范围内。 */
export function allowedLocally(refs: Map<string, Ref[]> | null, vaultId: string, name: string): boolean {
  if (refs === null) return true;
  return (refs.get(vaultId) ?? []).some((r) => covers(r, name));
}

/** 客户端设备能否写入（或删除）某变量库里的某个变量：需要读写、本机解密的授权，且有一条可以修改的引用覆盖它。 */
export function canWrite(sql: Sql, d: Device, vaultId: string, name: string, now: number): boolean {
  if (d.kind === "manager") return true;
  return grantedEnvs(sql, d, now).some(
    (e) => e.role === "rw" && e.local_decrypt === 1 && e.refs.some((r) => r.vaultId === vaultId && r.writable && covers(r, name)),
  );
}

/** 设备全部开启本机解密的授权（不论是否到期）引用到的、现存的变量库。 */
export function requiredVaults(sql: Sql, deviceId: string): Set<string> {
  const existing = new Set(sql.all<{ id: string }>(`SELECT id FROM vaults`).map((v) => v.id));
  const out = new Set<string>();
  const rows = sql.all<{ refs: string }>(
    `SELECT e.refs FROM grants g JOIN environments e ON e.id = g.environment_id WHERE g.device_id = ? AND g.local_decrypt = 1`,
    deviceId,
  );
  for (const r of rows) for (const ref of parseStoredRefs(r.refs)) if (existing.has(ref.vaultId)) out.add(ref.vaultId);
  return out;
}

/**
 * 让客户端设备的封装与它的授权一致：写入新提供的封装（必须是需要的），检查需要的都有，删除不再需要的。
 * 在事务中调用。
 */
export function reconcileEnvelopes(sql: Sql, deviceId: string, provided: Envelope[]) {
  const need = requiredVaults(sql, deviceId);
  if (provided.some((e) => !need.has(e.vaultId))) throw bad("提供的封装对应的变量库不在这台设备开启本机解密的范围内。");
  checkKeyVersions(sql, provided);
  insertEnvelopes(sql, provided);
  const have = new Set(
    sql.all<{ vault_id: string }>(`SELECT vault_id FROM envelopes WHERE recipient = ?`, deviceId).map((e) => e.vault_id),
  );
  for (const v of need) {
    if (!have.has(v)) throw bad("开启本机解密的授权需要附带它引用的变量库的封装，请同步后重试。");
  }
  for (const v of have) {
    if (!need.has(v)) sql.run(`DELETE FROM envelopes WHERE recipient = ? AND vault_id = ?`, deviceId, v);
  }
}

/** 记录这些设备能看到的变量范围变了，下次同步下发完整列表。 */
export function touchVisibility(sql: Sql, deviceIds: string[], seq: number) {
  for (const id of deviceIds) sql.run(`UPDATE devices SET visibility_seq = ? WHERE id = ?`, seq, id);
}

/** 被授权某个环境的全部设备。 */
export function devicesWithEnv(sql: Sql, envId: string): string[] {
  return sql.all<{ device_id: string }>(`SELECT device_id FROM grants WHERE environment_id = ?`, envId).map((g) => g.device_id);
}

/** 全部活跃的客户端设备。 */
export function clientDevices(sql: Sql): string[] {
  return sql.all<{ id: string }>(`SELECT id FROM devices WHERE kind = 'client' AND status = 'active'`).map((d) => d.id);
}
