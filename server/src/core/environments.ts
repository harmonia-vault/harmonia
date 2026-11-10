// 环境：由对变量库的引用组成（docs/protocol.md 3.2，设计文档 17.1）。
import type { Hono } from "hono";
import { bump, headSeq, one, type Sql } from "./db";
import { readJson, requireDevice, requireInitialized, type Deps } from "./context";
import { devicesWithEnv, parseStoredRefs, reconcileEnvelopes, touchVisibility, vaultNames } from "./access";
import { renumber } from "./grants";
import { parseEnvelopes, type Envelope } from "./keys";
import { duplicateNames, parseRefs, type Ref } from "./refs";
import { arr, bad, conflict, id, label, notFound, obj } from "./util";

/** 检查引用的变量库存在（原来就引用、后来被删除的可以保留）以及最终名字不重复。 */
function checkRefs(sql: Sql, refs: Ref[], previous: Ref[]) {
  const kept = new Set(previous.map((r) => r.vaultId));
  for (const r of refs) {
    if (!one(sql, `SELECT 1 FROM vaults WHERE id = ?`, r.vaultId) && !kept.has(r.vaultId)) {
      throw bad("引用的变量库不存在，请同步后重试。");
    }
  }
  const dup = duplicateNames(refs, vaultNames(sql));
  if (dup.length) throw conflict(`环境里有重名的变量：${dup.join("、")}。请给其中一个改名，或取消勾选。`);
}

/** 环境名不能重复：去掉首尾空白后不区分大小写比较（设计文档 19.2）。 */
function checkName(sql: Sql, name: string, envId: string) {
  const key = name.toLowerCase();
  const taken = sql.all<{ name: string }>(`SELECT name FROM environments WHERE id != ?`, envId).some((e) => e.name.trim().toLowerCase() === key);
  if (taken) throw conflict(`已经有名为“${name}”的环境，请换一个名字。`);
}

function storedRefs(refs: Ref[]): string {
  return JSON.stringify(
    refs.map((r) => ({ vaultId: r.vaultId, scope: r.scope, items: r.items.map((i) => (i.as ? { name: i.name, as: i.as } : { name: i.name })) })),
  );
}

export function environmentRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;
  const changed = () => deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
  const requireEnv = (envId: string) => {
    const e = one<{ id: string; refs: string }>(sql, `SELECT id, refs FROM environments WHERE id = ?`, envId);
    if (!e) throw notFound("环境不存在，可能已被删除。");
    return e;
  };

  app.post("/api/v1/environments", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const body = await readJson(c);
    const envId = id(body.id, "环境 ID");
    const name = label(body.name, "环境名");
    const refs = parseRefs(body.refs);
    if (arr(body.envelopes ?? [], "封装列表").length) throw bad("新环境还没有授权给任何设备，不需要封装。");
    sql.transaction(() => {
      if (one(sql, `SELECT 1 FROM environments WHERE id = ?`, envId)) throw conflict("环境已存在。");
      checkName(sql, name, envId);
      checkRefs(sql, refs, []);
      sql.run(`INSERT INTO environments (id, name, refs, created_at) VALUES (?, ?, ?, ?)`, envId, name, storedRefs(refs), deps.now());
      bump(sql);
    });
    changed();
    return c.json({ ok: true });
  });

  // 整体替换名字和引用；新引用的变量库要为开启本机解密的设备附带封装（docs/protocol.md 3.2）。
  app.put("/api/v1/environments/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = requireInitialized(sql);
    const envId = id(c.req.param("id"), "环境 ID");
    const body = await readJson(c);
    const name = label(body.name, "环境名");
    const refs = parseRefs(body.refs);
    const byRecipient = new Map<string, unknown[]>();
    for (const item of arr(body.envelopes ?? [], "封装列表")) {
      const recipient = id(obj(item, "封装").recipient, "接收设备 ID");
      byRecipient.set(recipient, [...(byRecipient.get(recipient) ?? []), item]);
    }
    const provided = new Map<string, Envelope[]>();
    for (const [recipient, list] of byRecipient) provided.set(recipient, await parseEnvelopes(a.root_pub, recipient, list));
    sql.transaction(() => {
      const env = requireEnv(envId);
      checkName(sql, name, envId);
      checkRefs(sql, refs, parseStoredRefs(env.refs));
      const devices = devicesWithEnv(sql, envId);
      if ([...provided.keys()].some((r) => !devices.includes(r))) throw bad("封装的接收设备没有被授权这个环境。");
      sql.run(`UPDATE environments SET name = ?, refs = ? WHERE id = ?`, name, storedRefs(refs), envId);
      for (const dev of devices) reconcileEnvelopes(sql, dev, provided.get(dev) ?? []);
      touchVisibility(sql, devices, bump(sql));
    });
    changed();
    return c.json({ ok: true });
  });

  app.delete("/api/v1/environments/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const envId = id(c.req.param("id"), "环境 ID");
    sql.transaction(() => {
      requireEnv(envId);
      const devices = devicesWithEnv(sql, envId);
      sql.run(`DELETE FROM grants WHERE environment_id = ?`, envId);
      sql.run(`DELETE FROM environments WHERE id = ?`, envId);
      for (const dev of devices) {
        reconcileEnvelopes(sql, dev, []);
        renumber(sql, dev);
      }
      touchVisibility(sql, devices, bump(sql));
    });
    changed();
    return c.json({ ok: true });
  });
}
