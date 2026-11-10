// 变量库与其中的变量（docs/protocol.md 3.2）。
import type { Context, Hono } from "hono";
import { bump, headSeq, one } from "./db";
import { readJson, requireDevice, requireInitialized, type Deps, type Device } from "./context";
import { canWrite, clientDevices, touchVisibility } from "./access";
import {
  ApiError,
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
} from "./util";

type VaultRow = { id: string; name: string; key_version: number };

// 变量明文是最长 512 KiB 的 JSON（docs/protocol.md 2.6），加上 24 字节 nonce 和 16 字节 tag。
const MAX_VALUE_B64 = Math.ceil(((512 * 1024 + 40) * 4) / 3);

/** 批量写入一次最多的变量数（docs/protocol.md 3.2）。 */
const MAX_BATCH = 100;

function requireVault(deps: Deps, vaultId: string): VaultRow {
  const v = one<VaultRow>(deps.sql, `SELECT id, name, key_version FROM vaults WHERE id = ?`, vaultId);
  if (!v) throw notFound("变量库不存在，可能已被删除。");
  return v;
}

/** 检查设备能写这些变量，并返回变量库。 */
function requireWritable(deps: Deps, d: Device, vaultId: string, names: string[]): VaultRow {
  const v = requireVault(deps, vaultId);
  for (const name of names) {
    if (!canWrite(deps.sql, d, vaultId, name, deps.now())) {
      throw forbidden(`这台设备不能修改 ${name}：需要在管理设备上为它所在的环境授予读写权限。`);
    }
  }
  return v;
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

function parseBody(text: string): Record<string, unknown> {
  try {
    return obj(JSON.parse(text));
  } catch {
    throw bad("请求内容不是有效的 JSON。");
  }
}

export function vaultRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;
  const changed = () => deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });

  const writeVar = (vaultId: string, name: string, value: string, keyVersion: number, seq: number, by: string) =>
    sql.run(
      `INSERT OR REPLACE INTO variables (vault_id, name, value, key_version, deleted, seq, updated_by, updated_at)
       VALUES (?, ?, ?, ?, 0, ?, ?, ?)`,
      vaultId,
      name,
      value,
      keyVersion,
      seq,
      by,
      deps.now(),
    );
  const deleteVar = (vaultId: string, name: string, seq: number, by: string) =>
    sql.run(
      `UPDATE variables SET value = '', deleted = 1, seq = ?, updated_by = ?, updated_at = ?
       WHERE vault_id = ? AND name = ? AND deleted = 0`,
      seq,
      by,
      deps.now(),
      vaultId,
      name,
    );

  app.post("/api/v1/vaults", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const vaultId = id(body.id, "变量库 ID");
    const name = label(body.name, "变量库名");
    const envelopes: { recipient: string; sealed: string; sig: string }[] = [];
    for (const item of arr(body.envelopes, "封装列表")) {
      const e = obj(item, "封装");
      const recipient = e.recipient === "recovery" ? "recovery" : id(e.recipient, "接收设备 ID");
      if (decimal(e.keyVersion ?? "1", "密钥版本") !== 1) throw bad("新变量库的密钥版本必须为 1。");
      const sealed = bin(e.sealed, "封装内容", 80);
      const sig = bin(e.sig, "封装签名", 64);
      if (!(await verifyEd25519(a.root_pub, await envelopeMsg(vaultId, 1, recipient, sealed), sig))) {
        throw bad("封装签名无效。");
      }
      envelopes.push({ recipient, sealed, sig });
    }
    sql.transaction(() => {
      if (one(sql, `SELECT 1 FROM vaults WHERE id = ?`, vaultId)) throw conflict("变量库已存在。");
      const managers = sql.all<{ id: string }>(`SELECT id FROM devices WHERE kind = 'manager' AND status = 'active'`);
      const want = new Set([...managers.map((m) => m.id), "recovery"]);
      const got = new Set(envelopes.map((e) => e.recipient));
      if (got.size !== envelopes.length || got.size !== want.size || [...want].some((r) => !got.has(r))) {
        throw bad("需要为全部管理设备和恢复码提供封装，请同步后重试。");
      }
      sql.run(`INSERT INTO vaults (id, name, key_version, created_at) VALUES (?, ?, 1, ?)`, vaultId, name, deps.now());
      for (const e of envelopes) {
        sql.run(
          `INSERT INTO envelopes (vault_id, key_version, recipient, sealed, sig) VALUES (?, 1, ?, ?, ?)`,
          vaultId,
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

  app.patch("/api/v1/vaults/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const v = requireVault(deps, id(c.req.param("id"), "变量库 ID"));
    const name = label((await readJson(c)).name, "变量库名");
    sql.transaction(() => {
      sql.run(`UPDATE vaults SET name = ? WHERE id = ?`, name, v.id);
      bump(sql);
    });
    changed();
    return c.json({ ok: true });
  });

  // 删除变量库：引用它的环境保留引用，标记为已失效（docs/protocol.md 3.2）。
  app.delete("/api/v1/vaults/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const v = requireVault(deps, id(c.req.param("id"), "变量库 ID"));
    sql.transaction(() => {
      for (const t of ["variables", "envelopes"]) sql.run(`DELETE FROM ${t} WHERE vault_id = ?`, v.id);
      sql.run(`DELETE FROM vaults WHERE id = ?`, v.id);
      touchVisibility(sql, clientDevices(sql), bump(sql));
    });
    changed();
    return c.json({ ok: true });
  });

  app.put("/api/v1/vaults/:id/variables/:name", async (c) => {
    const d = await requireDevice(c, deps);
    const vaultId = id(c.req.param("id"), "变量库 ID");
    const name = varName(c.req.param("name"));
    const text = await c.req.text();
    const body = parseBody(text);
    const value = bin(body.value, "变量值", undefined, MAX_VALUE_B64);
    const keyVersion = decimal(body.keyVersion, "密钥版本");
    const res = await idempotent(c, deps, d, text, () => {
      const v = requireWritable(deps, d, vaultId, [name]);
      if (v.key_version !== keyVersion) throw conflict("变量库密钥已更新，请同步后重试。");
      const seq = bump(sql);
      writeVar(vaultId, name, value, keyVersion, seq, d.id);
      return { seq };
    });
    changed();
    return c.json(res);
  });

  // 批量写入：整批在一个事务中生效，共用一个 seq（docs/protocol.md 3.2）。
  app.patch("/api/v1/vaults/:id/variables", async (c) => {
    const d = await requireDevice(c, deps);
    const vaultId = id(c.req.param("id"), "变量库 ID");
    const text = await c.req.text();
    if (text.length > 2_000_000) throw new ApiError(413, "invalid_request", "请求内容过大，请分批写入。");
    const body = parseBody(text);
    const keyVersion = decimal(body.keyVersion, "密钥版本");
    const set = arr(body.set ?? [], "要写入的变量").map((v) => {
      const o = obj(v);
      return { name: varName(o.name), value: bin(o.value, "变量值", undefined, MAX_VALUE_B64) };
    });
    const del = arr(body.delete ?? [], "要删除的变量").map((v) => varName(v));
    const total = set.length + del.length;
    if (total === 0) throw bad("没有要写入或删除的变量。");
    if (total > MAX_BATCH) throw bad(`一次最多写入 ${MAX_BATCH} 个变量，请分批写入。`);
    const names = new Set<string>();
    for (const n of [...set.map((v) => v.name), ...del]) {
      if (names.has(n)) throw bad(`变量 ${n} 在同一批中出现了多次。`);
      names.add(n);
    }
    const res = await idempotent(c, deps, d, text, () => {
      const v = requireWritable(deps, d, vaultId, [...names]);
      if (v.key_version !== keyVersion) throw conflict("变量库密钥已更新，请同步后重试。");
      const seq = bump(sql);
      for (const x of set) writeVar(vaultId, x.name, x.value, keyVersion, seq, d.id);
      for (const name of del) deleteVar(vaultId, name, seq, d.id);
      return { seq };
    });
    changed();
    return c.json(res);
  });

  app.delete("/api/v1/vaults/:id/variables/:name", async (c) => {
    const d = await requireDevice(c, deps);
    const vaultId = id(c.req.param("id"), "变量库 ID");
    const name = varName(c.req.param("name"));
    const res = await idempotent(c, deps, d, "", () => {
      requireWritable(deps, d, vaultId, [name]);
      const cur = one<{ deleted: number }>(sql, `SELECT deleted FROM variables WHERE vault_id = ? AND name = ?`, vaultId, name);
      if (!cur || cur.deleted) return { seq: headSeq(sql) };
      const seq = bump(sql);
      deleteVar(vaultId, name, seq, d.id);
      return { seq };
    });
    changed();
    return c.json(res);
  });
}
