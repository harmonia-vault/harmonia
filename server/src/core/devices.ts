// 设备管理：授权调整、改名、撤销与本机退出。
import type { Hono } from "hono";
import { bump, headSeq, one, type Sql } from "./db";
import { readJson, requireDevice, requireInitialized, type Deps, type Device } from "./context";
import { checkKeyVersions, insertEnvelopes, parseEnvelopes } from "./keys";
import { parseGrants, writeGrants } from "./grants";
import { bad, conflict, id, label, notFound } from "./util";

function target(sql: Sql, deviceId: string): Device {
  const d = one<Device>(sql, `SELECT * FROM devices WHERE id = ? AND status = 'active'`, deviceId);
  if (!d) throw notFound("设备不存在或已被移除。");
  return d;
}

function activeManagerCount(sql: Sql): number {
  return one<{ n: number }>(sql, `SELECT COUNT(*) AS n FROM devices WHERE kind = 'manager' AND status = 'active'`)!.n;
}

export function revokeDevice(deps: Deps, deviceId: string) {
  const { sql } = deps;
  sql.transaction(() => {
    sql.run(`UPDATE devices SET status = 'revoked', root_sealed = NULL WHERE id = ?`, deviceId);
    sql.run(`DELETE FROM grants WHERE device_id = ?`, deviceId);
    sql.run(`DELETE FROM envelopes WHERE recipient = ?`, deviceId);
    sql.run(`DELETE FROM sessions WHERE device_id = ?`, deviceId);
    bump(sql);
  });
  deps.notifier.send({ device: deviceId }, { type: "revoked" });
  deps.notifier.disconnect(deviceId);
  deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
}

export function deviceRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

  app.put("/api/v1/devices/:id/grants", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = requireInitialized(sql);
    const t = target(sql, id(c.req.param("id"), "设备 ID"));
    if (t.kind !== "client") throw bad("管理手机拥有全部环境的权限，不需要单独授权。");
    const body = await readJson(c);
    const grants = parseGrants(body.grants);
    const envelopes = await parseEnvelopes(a.root_pub, t.id, body.envelopes);
    sql.transaction(() => {
      checkKeyVersions(sql, envelopes);
      const current = new Set(sql.all<{ env_id: string }>(`SELECT env_id FROM grants WHERE device_id = ?`, t.id).map((g) => g.env_id));
      const provided = new Set(envelopes.map((e) => e.envId));
      const wanted = new Set(grants.map((g) => g.envId));
      for (const g of grants) {
        if (!current.has(g.envId) && !provided.has(g.envId)) throw bad("新授权的环境需要附带封装，请同步后重试。");
      }
      if ([...provided].some((e) => !wanted.has(e))) throw bad("封装对应的环境不在授权列表中。");
      for (const envId of current) {
        if (!wanted.has(envId)) {
          sql.run(`DELETE FROM grants WHERE device_id = ? AND env_id = ?`, t.id, envId);
          sql.run(`DELETE FROM envelopes WHERE recipient = ? AND env_id = ?`, t.id, envId);
        }
      }
      insertEnvelopes(sql, envelopes);
      const seq = bump(sql);
      writeGrants(sql, t.id, grants, seq);
    });
    deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
    return c.json({ ok: true });
  });

  app.patch("/api/v1/devices/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const t = target(sql, id(c.req.param("id"), "设备 ID"));
    const name = label((await readJson(c)).name, "设备名");
    sql.transaction(() => {
      sql.run(`UPDATE devices SET name = ? WHERE id = ?`, name, t.id);
      bump(sql);
    });
    deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
    return c.json({ ok: true });
  });

  app.post("/api/v1/devices/self/revoke", async (c) => {
    const d = await requireDevice(c, deps, { allowRotation: true });
    const body = await readJson(c).catch(() => ({}) as Record<string, unknown>);
    if (d.kind === "manager" && activeManagerCount(sql) === 1 && body.confirmLast !== true) {
      throw conflict("这是账号里唯一的管理手机。退出后只能用恢复码找回账号。");
    }
    revokeDevice(deps, d.id);
    return c.json({ ok: true });
  });

  app.post("/api/v1/devices/:id/revoke", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const t = target(sql, id(c.req.param("id"), "设备 ID"));
    if (t.kind === "manager" && activeManagerCount(sql) === 1) {
      throw conflict("不能移除最后一台管理手机。");
    }
    revokeDevice(deps, t.id);
    return c.json({ ok: true });
  });
}
