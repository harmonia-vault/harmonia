// 推送连接与同步（docs/protocol.md 3.4、3.5）。
import type { Hono } from "hono";
import { bump, headSeq } from "./db";
import { activeManagers, requireDevice, requireInitialized, type Deps, type Device } from "./context";
import { allowedLocally, grantedEnvs, localRefs, parseStoredRefs, vaultNames, type EnvRow } from "./access";
import { expand } from "./refs";
import { bad, clientVersion, VERSION_HEADER } from "./util";

type VaultRow = { id: string; name: string; key_version: number };
type VarRow = { vault_id: string; name: string; value: string; key_version: number; deleted: number; seq: number };

export function syncRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

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
    // 版本变化时通知管理设备，设备列表随之显示新版本（docs/protocol.md 3.4）。
    const version = clientVersion(c.req.header(VERSION_HEADER)) ?? d.version;
    const versionChanged = version !== d.version;
    sql.transaction(() => {
      sql.run(`UPDATE devices SET last_seen_at = ?, version = ? WHERE id = ?`, deps.now(), version, d.id);
      if (versionChanged) bump(sql);
    });
    if (versionChanged) deps.notifier.send("managers", { type: "changed", seq: headSeq(sql) });
    return c.json(snapshot(deps, d, since));
  });
}

/** 一次同步的响应：在同一时刻读出，避免各部分不一致。 */
function snapshot(deps: Deps, d: Device, since: number): Record<string, unknown> {
  const { sql } = deps;
  return sql.transaction(() => {
    const seq = headSeq(sql);
    const now = deps.now();
    const names = vaultNames(sql);
    const allVaults = sql.all<VaultRow>(`SELECT id, name, key_version FROM vaults ORDER BY created_at`);
    const vaultById = new Map(allVaults.map((v) => [v.id, v]));
    const envs = grantedEnvs(sql, d, now);
    const local = localRefs(sql, d, now);
    const localVaults = allVaults.filter((v) => local === null || local.has(v.id));
    const localIds = localVaults.map((v) => v.id);
    // 能看到的变量范围变了（授权、引用变化）时下发完整列表，客户端据此替换缓存（docs/protocol.md 3.4）。
    const full = since === 0 || (d.kind === "client" && d.visibility_seq > since);
    const marks = localIds.map(() => "?").join(",");
    const vars = localIds.length
      ? sql.all<VarRow>(
          full
            ? `SELECT vault_id, name, value, key_version, deleted, seq FROM variables WHERE deleted = 0 AND vault_id IN (${marks}) ORDER BY seq`
            : `SELECT vault_id, name, value, key_version, deleted, seq FROM variables WHERE seq > ? AND vault_id IN (${marks}) ORDER BY seq`,
          ...(full ? localIds : [since, ...localIds]),
        )
      : [];
    const envelopes = localIds.length
      ? sql.all<{ vault_id: string; key_version: number; sealed: string; sig: string }>(
          `SELECT vault_id, key_version, sealed, sig FROM envelopes WHERE recipient = ? AND vault_id IN (${marks})`,
          d.id,
          ...localIds,
        )
      : [];
    const referenced = new Set(envs.flatMap((e) => e.refs.map((r) => r.vaultId)));
    const out: Record<string, unknown> = {
      seq,
      full,
      self: {
        id: d.id,
        kind: d.kind,
        name: d.name,
        rotationRequired: !!d.rotation_required,
        systemVars: !!d.system_vars,
        autoUpdate: !!d.auto_update,
      },
      environments: envs.map((e) => {
        const { items, shadowed } = expand(e.refs, names);
        return {
          id: e.id,
          name: e.name,
          role: e.role,
          expiresAt: e.expires_at,
          localDecrypt: e.local_decrypt === 1,
          active: e.active === 1,
          position: e.position,
          items,
          shadowed,
          createVaults: e.refs.filter((r) => r.scope === "all" && r.writable && vaultById.has(r.vaultId)).map((r) => r.vaultId),
        };
      }),
      vaultNames: allVaults.filter((v) => referenced.has(v.id)).map((v) => ({ id: v.id, name: v.name })),
      vaults: localVaults.map((v) => ({ id: v.id, keyVersion: String(v.key_version) })),
      envelopes: envelopes.map((e) => ({ vaultId: e.vault_id, keyVersion: String(e.key_version), sealed: e.sealed, sig: e.sig })),
      variables: vars
        .filter((v) => allowedLocally(local, v.vault_id, v.name))
        .map((v) => ({
          vaultId: v.vault_id,
          name: v.name,
          value: v.value,
          keyVersion: String(v.key_version),
          deleted: !!v.deleted,
          seq: v.seq,
        })),
    };
    out.managers = activeManagers(sql).map((m) => ({ id: m.id, signPub: m.sign_pub, boxPub: m.box_pub, cert: m.cert }));
    if (d.kind === "manager") out.manager = managerPart(deps, d, allVaults, vaultById);
    return out;
  });
}

function managerPart(deps: Deps, d: Device, allVaults: VaultRow[], vaultById: Map<string, VaultRow>) {
  const { sql } = deps;
  const a = requireInitialized(sql);
  const devices = sql.all<Device>(`SELECT * FROM devices WHERE status = 'active' ORDER BY created_at`);
  const grants = sql.all<{
    device_id: string;
    environment_id: string;
    role: string;
    expires_at: number;
    local_decrypt: number;
    active: number;
    position: number;
  }>(`SELECT device_id, environment_id, role, expires_at, local_decrypt, active, position FROM grants ORDER BY position`);
  const envs = sql.all<EnvRow>(`SELECT id, name, refs, created_at FROM environments ORDER BY created_at`);
  return {
    rootSealed: d.root_sealed,
    recovery: { generation: String(a.recovery_generation), boxPub: a.recovery_box_pub },
    vaults: allVaults.map((v) => ({ id: v.id, name: v.name, keyVersion: String(v.key_version) })),
    environments: envs.map((e) => ({
      id: e.id,
      name: e.name,
      refs: parseStoredRefs(e.refs).map((r) => ({ ...r, missing: !vaultById.has(r.vaultId) })),
    })),
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
      version: x.version,
      systemVars: !!x.system_vars,
      autoUpdate: !!x.auto_update,
      grants: grants
        .filter((g) => g.device_id === x.id)
        .map((g) => ({
          environmentId: g.environment_id,
          role: g.role,
          expiresAt: g.expires_at,
          localDecrypt: g.local_decrypt === 1,
          active: g.active === 1,
          position: g.position,
        })),
    })),
  };
}
