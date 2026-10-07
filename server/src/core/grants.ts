// 客户端设备的环境授权，以及授权上的激活状态和顺序（docs/protocol.md 3.2、3.4）。
import type { Sql } from "./db";
import { arr, bad, conflict, id, int, obj, role, type Role } from "./util";

export type Grant = { envId: string; role: Role; expiresAt: number };

export function parseGrants(raw: unknown): Grant[] {
  const out = arr(raw ?? [], "授权列表").map((item) => {
    const g = obj(item, "授权");
    return { envId: id(g.envId, "环境 ID"), role: role(g.role), expiresAt: int(g.expiresAt ?? 0, "有效期") };
  });
  if (new Set(out.map((g) => g.envId)).size !== out.length) throw bad("授权列表中有重复的环境。");
  return out;
}

/**
 * 写入授权；seq 用于让设备在下一次同步时拉取新授权环境中的全部变量。
 * 已有授权保留激活状态和顺序，新授权默认激活并排在最后。
 */
export function writeGrants(sql: Sql, deviceId: string, grants: Grant[], seq: number) {
  for (const g of grants) {
    if (!sql.all(`SELECT 1 FROM environments WHERE id = ?`, g.envId).length) throw bad("要授权的环境不存在。");
    sql.run(
      `INSERT INTO grants (device_id, env_id, role, expires_at, seq, active, position)
       VALUES (?, ?, ?, ?, ?, 1, (SELECT COALESCE(MAX(position) + 1, 0) FROM grants WHERE device_id = ?))
       ON CONFLICT (device_id, env_id) DO UPDATE SET role = excluded.role, expires_at = excluded.expires_at, seq = excluded.seq`,
      deviceId,
      g.envId,
      g.role,
      g.expiresAt,
      seq,
      deviceId,
    );
  }
  renumber(sql, deviceId);
}

/** 把顺序整理为从 0 开始的连续编号（删除授权后会留下空位）。 */
export function renumber(sql: Sql, deviceId: string) {
  const rows = sql.all<{ env_id: string }>(`SELECT env_id FROM grants WHERE device_id = ? ORDER BY position, rowid`, deviceId);
  rows.forEach((r, i) => sql.run(`UPDATE grants SET position = ? WHERE device_id = ? AND env_id = ?`, i, deviceId, r.env_id));
}

/**
 * 按给定顺序整体设置激活状态。列表必须包含该设备全部未到期的授权，可以带上已到期的；
 * 没有列出的已到期授权保持原有相对顺序，排在后面。
 */
export function writeActivation(sql: Sql, deviceId: string, raw: unknown, now: number) {
  const envs = arr(raw, "环境列表").map((item) => {
    const e = obj(item, "环境");
    if (typeof e.active !== "boolean") throw bad("active 字段格式不对。");
    return { envId: id(e.envId, "环境 ID"), active: e.active };
  });
  const current = sql.all<{ env_id: string; expires_at: number }>(
    `SELECT env_id, expires_at FROM grants WHERE device_id = ? ORDER BY position`,
    deviceId,
  );
  const granted = new Set(current.map((g) => g.env_id));
  const given = new Set(envs.map((e) => e.envId));
  const valid = current.filter((g) => g.expires_at === 0 || g.expires_at > now);
  if (given.size !== envs.length || envs.some((e) => !granted.has(e.envId)) || valid.some((g) => !given.has(g.env_id))) {
    throw conflict("这台设备的授权已经变化，请同步后重试。");
  }
  envs.forEach((e, i) =>
    sql.run(`UPDATE grants SET active = ?, position = ? WHERE device_id = ? AND env_id = ?`, e.active ? 1 : 0, i, deviceId, e.envId),
  );
  current
    .filter((g) => !given.has(g.env_id))
    .forEach((g, i) => sql.run(`UPDATE grants SET position = ? WHERE device_id = ? AND env_id = ?`, envs.length + i, deviceId, g.env_id));
}
