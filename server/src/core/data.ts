// 同步、环境与变量（docs/protocol.md 3.4）。
import type { Context, Hono } from "hono";
import { bump, headSeq, one } from "./db";
import { envRole, readJson, requireDevice, requireInitialized, type Deps, type Device } from "./context";
import {
  arr,
  b64,
  bad,
  bin,
  conflict,
  decimal,
  envelopeMsg,
  forbidden,
  id,
  label,
  notFound,
  obj,
  sha256,
  utf8,
  varName,
  verifyEd25519,
  type Role,
} from "./util";

type EnvRow = { id: string; name: string; key_version: number };
type VarRow = { env_id: string; name: string; value: string; key_version: number; deleted: number; seq: number };

const MAX_VALUE_B64 = Math.ceil(((65536 + 40) * 4) / 3);

/** 设备当前可访问的环境（含权限与到期时间）。 */
function accessible(deps: Deps, d: Device): (EnvRow & { role: Role; expires_at: number; grant_seq: number })[] {
  if (d.kind === "manager") {
    return deps.sql
      .all<EnvRow>(`SELECT id, name, key_version FROM environments ORDER BY created_at`)
      .map((e) => ({ ...e, role: "admin" as Role, expires_at: 0, grant_seq: 0 }));
  }
  return deps.sql.all(
    `SELECT e.id, e.name, e.key_version, g.role, g.expires_at, g.seq AS grant_seq
     FROM grants g JOIN environments e ON e.id = g.env_id
     WHERE g.device_id = ? AND (g.expires_at = 0 OR g.expires_at > ?) ORDER BY e.created_at`,
    d.id,
    deps.now(),
  );
}

function requireEnvRole(deps: Deps, d: Device, envId: string, need: "rw" | "admin"): EnvRow {
  const env = one<EnvRow>(deps.sql, `SELECT id, name, key_version FROM environments WHERE id = ?`, envId);
  if (!env) throw notFound("环境不存在，可能已被删除。");
  const r = envRole(deps, d, envId);
  if (!r) throw forbidden("这台设备没有这个环境的访问权限，或授权已到期。");
  if (need === "rw" && r === "ro") throw forbidden("这台设备对这个环境只有只读权限。");
  if (need === "admin" && r !== "admin") throw forbidden("只有管理权限才能修改环境。");
  return env;
}

/** 带幂等键的写操作：相同请求重放返回原结果，同键不同内容拒绝。 */
async function idempotent(c: Context, deps: Deps, d: Device, body: string, fn: () => object): Promise<object> {
  const key = c.req.header("idempotency-key") ?? "";
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(key)) throw bad("缺少有效的 Idempotency-Key 请求头。");
  const hash = b64(await sha256(utf8(`${c.req.method} ${new URL(c.req.url).pathname}\n${body}`)));
  return deps.sql.transaction(() => {
    const prev = one<{ request_hash: string; response: string }>(
      deps.sql,
      `SELECT request_hash, response FROM idempotency WHERE device_id = ? AND key = ?`,
      d.id,
      key,
    );
    if (prev) {
      if (prev.request_hash !== hash) throw conflict("这个操作编号已用于其他请求，请重试。");
      return JSON.parse(prev.response) as object;
    }
    const res = fn();
    deps.sql.run(
      `INSERT INTO idempotency (device_id, key, request_hash, response, created_at) VALUES (?, ?, ?, ?, ?)`,
      d.id,
      key,
      hash,
      JSON.stringify(res),
      deps.now(),
    );
    return res;
  });
}

export function dataRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;
  const changed = () => deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });

  app.get("/api/v1/events", async (c) => {
    const d = await requireDevice(c, deps, { allowRotation: true });
    if (c.req.header("upgrade")?.toLowerCase() !== "websocket" || !deps.acceptSocket) {
      throw bad("推送接口需要使用 WebSocket 连接。");
    }
    return deps.acceptSocket(d);
  });

  app.get("/api/v1/sync", async (c) => {
    const d = await requireDevice(c, deps, { allowRotation: true });
    const sinceRaw = c.req.query("since") ?? "0";
    if (!/^[0-9]{1,15}$/.test(sinceRaw)) throw bad("since 参数格式不对。");
    const since = Number(sinceRaw);
    const seq = headSeq(sql);
    const envs = accessible(deps, d);
    const ids = envs.map((e) => e.id);
    const fresh = new Set(envs.filter((e) => since === 0 || e.grant_seq > since).map((e) => e.id));
    const envelopes = ids.length
      ? sql.all<{ env_id: string; key_version: number; sealed: string; sig: string }>(
          `SELECT env_id, key_version, sealed, sig FROM envelopes WHERE recipient = ? AND env_id IN (${ids.map(() => "?").join(",")})`,
          d.id,
          ...ids,
        )
      : [];
    const vars = ids.length
      ? sql.all<VarRow>(
          `SELECT env_id, name, value, key_version, deleted, seq FROM variables
           WHERE env_id IN (${ids.map(() => "?").join(",")}) AND (seq > ? OR env_id IN (${[...fresh].map(() => "?").join(",") || "''"}))
           ORDER BY seq`,
          ...ids,
          since,
          ...fresh,
        )
      : [];
    sql.run(`UPDATE devices SET last_seen_at = ? WHERE id = ?`, deps.now(), d.id);
    const out: Record<string, unknown> = {
      seq,
      self: { id: d.id, kind: d.kind, name: d.name, rotationRequired: !!d.rotation_required },
      environments: envs.map((e) => ({
        id: e.id,
        name: e.name,
        keyVersion: String(e.key_version),
        role: e.role,
        expiresAt: e.expires_at,
      })),
      envelopes: envelopes.map((e) => ({ envId: e.env_id, keyVersion: String(e.key_version), sealed: e.sealed, sig: e.sig })),
      variables: vars
        .filter((v) => !(v.deleted && (since === 0 || fresh.has(v.env_id))))
        .map((v) => ({
          envId: v.env_id,
          name: v.name,
          value: v.value,
          keyVersion: String(v.key_version),
          deleted: !!v.deleted,
          seq: v.seq,
        })),
    };
    if (d.kind === "manager") {
      const a = requireInitialized(sql);
      const devices = sql.all<Device>(`SELECT * FROM devices WHERE status = 'active' ORDER BY created_at`);
      const grants = sql.all<{ device_id: string; env_id: string; role: string; expires_at: number }>(
        `SELECT device_id, env_id, role, expires_at FROM grants`,
      );
      out.manager = {
        rootSealed: d.root_sealed,
        recovery: { generation: String(a.recovery_generation), boxPub: a.recovery_box_pub },
        devices: devices.map((x) => ({
          id: x.id,
          name: x.name,
          platform: x.platform,
          kind: x.kind,
          signPub: x.sign_pub,
          boxPub: x.box_pub,
          cert: x.cert,
          createdAt: x.created_at,
          lastSeenAt: x.last_seen_at,
          grants: grants
            .filter((g) => g.device_id === x.id)
            .map((g) => ({ envId: g.env_id, role: g.role, expiresAt: g.expires_at })),
        })),
      };
    }
    return c.json(out);
  });

  app.post("/api/v1/environments", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const envId = id(body.id, "环境 ID");
    const name = label(body.name, "环境名");
    const envelopes: { recipient: string; sealed: string; sig: string }[] = [];
    for (const item of arr(body.envelopes, "封装列表")) {
      const e = obj(item, "封装");
      const recipient = e.recipient === "recovery" ? "recovery" : id(e.recipient, "接收设备 ID");
      if (decimal(e.keyVersion ?? "1", "密钥版本") !== 1) throw bad("新环境的密钥版本必须为 1。");
      const sealed = bin(e.sealed, "封装内容", 80);
      const sig = bin(e.sig, "封装签名", 64);
      if (!(await verifyEd25519(a.root_pub, await envelopeMsg(envId, 1, recipient, sealed), sig))) {
        throw bad("封装签名无效。");
      }
      envelopes.push({ recipient, sealed, sig });
    }
    sql.transaction(() => {
      if (one(sql, `SELECT 1 FROM environments WHERE id = ?`, envId)) throw conflict("环境已存在。");
      const managers = sql.all<{ id: string }>(`SELECT id FROM devices WHERE kind = 'manager' AND status = 'active'`);
      const want = new Set([...managers.map((m) => m.id), "recovery"]);
      const got = new Set(envelopes.map((e) => e.recipient));
      if (got.size !== envelopes.length || got.size !== want.size || [...want].some((r) => !got.has(r))) {
        throw bad("需要为全部管理设备和恢复码提供封装，请同步后重试。");
      }
      sql.run(`INSERT INTO environments (id, name, key_version, created_at) VALUES (?, ?, 1, ?)`, envId, name, deps.now());
      for (const e of envelopes) {
        sql.run(
          `INSERT INTO envelopes (env_id, key_version, recipient, sealed, sig) VALUES (?, 1, ?, ?, ?)`,
          envId,
          e.recipient,
          e.sealed,
          e.sig,
        );
      }
      bump(sql);
    });
    changed();
    return c.json({ ok: true });
  });

  app.patch("/api/v1/environments/:id", async (c) => {
    const d = await requireDevice(c, deps);
    const env = requireEnvRole(deps, d, id(c.req.param("id"), "环境 ID"), "admin");
    const name = label((await readJson(c)).name, "环境名");
    sql.transaction(() => {
      sql.run(`UPDATE environments SET name = ? WHERE id = ?`, name, env.id);
      bump(sql);
    });
    changed();
    return c.json({ ok: true });
  });

  app.delete("/api/v1/environments/:id", async (c) => {
    const d = await requireDevice(c, deps);
    const env = requireEnvRole(deps, d, id(c.req.param("id"), "环境 ID"), "admin");
    sql.transaction(() => {
      for (const t of ["variables", "envelopes", "grants"]) sql.run(`DELETE FROM ${t} WHERE env_id = ?`, env.id);
      sql.run(`DELETE FROM environments WHERE id = ?`, env.id);
      bump(sql);
    });
    changed();
    return c.json({ ok: true });
  });

  app.put("/api/v1/environments/:id/variables/:name", async (c) => {
    const d = await requireDevice(c, deps);
    const envId = id(c.req.param("id"), "环境 ID");
    const name = varName(c.req.param("name"));
    const text = await c.req.text();
    let body: Record<string, unknown>;
    try {
      body = obj(JSON.parse(text));
    } catch {
      throw bad("请求内容不是有效的 JSON。");
    }
    const value = bin(body.value, "变量值", undefined, MAX_VALUE_B64);
    const keyVersion = decimal(body.keyVersion, "密钥版本");
    const res = await idempotent(c, deps, d, text, () => {
      const env = requireEnvRole(deps, d, envId, "rw");
      if (env.key_version !== keyVersion) throw conflict("环境密钥已更新，请同步后重试。");
      const seq = bump(sql);
      sql.run(
        `INSERT OR REPLACE INTO variables (env_id, name, value, key_version, deleted, seq, updated_by, updated_at)
         VALUES (?, ?, ?, ?, 0, ?, ?, ?)`,
        envId,
        name,
        value,
        keyVersion,
        seq,
        d.id,
        deps.now(),
      );
      return { seq };
    });
    changed();
    return c.json(res);
  });

  app.delete("/api/v1/environments/:id/variables/:name", async (c) => {
    const d = await requireDevice(c, deps);
    const envId = id(c.req.param("id"), "环境 ID");
    const name = varName(c.req.param("name"));
    const res = await idempotent(c, deps, d, "", () => {
      requireEnvRole(deps, d, envId, "rw");
      const cur = one<{ deleted: number }>(sql, `SELECT deleted FROM variables WHERE env_id = ? AND name = ?`, envId, name);
      if (!cur || cur.deleted) return { seq: headSeq(sql) };
      const seq = bump(sql);
      sql.run(
        `UPDATE variables SET value = '', deleted = 1, seq = ?, updated_by = ?, updated_at = ? WHERE env_id = ? AND name = ?`,
        seq,
        d.id,
        deps.now(),
        envId,
        name,
      );
      return { seq };
    });
    changed();
    return c.json(res);
  });
}

