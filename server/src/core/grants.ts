// 客户端设备的环境授权。
import type { Sql } from "./db";
import { arr, bad, id, int, obj, role, type Role } from "./util";

export type Grant = { envId: string; role: Role; expiresAt: number };

export function parseGrants(raw: unknown): Grant[] {
  const out = arr(raw ?? [], "授权列表").map((item) => {
    const g = obj(item, "授权");
    return { envId: id(g.envId, "环境 ID"), role: role(g.role), expiresAt: int(g.expiresAt ?? 0, "有效期") };
  });
  if (new Set(out.map((g) => g.envId)).size !== out.length) throw bad("授权列表中有重复的环境。");
  return out;
}

/** 写入授权；seq 用于让设备在下一次同步时拉取新授权环境中的全部变量。 */
export function writeGrants(sql: Sql, deviceId: string, grants: Grant[], seq: number) {
  for (const g of grants) {
    if (!sql.all(`SELECT 1 FROM environments WHERE id = ?`, g.envId).length) throw bad("要授权的环境不存在。");
    sql.run(
      `INSERT OR REPLACE INTO grants (device_id, env_id, role, expires_at, seq) VALUES (?, ?, ?, ?, ?)`,
      deviceId,
      g.envId,
      g.role,
      g.expiresAt,
      seq,
    );
  }
}
