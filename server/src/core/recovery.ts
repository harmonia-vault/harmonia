// 恢复：凭恢复码登记新管理手机，并原子轮换恢复码（docs/protocol.md 3.6）。
import type { Hono } from "hono";
import { bump, headSeq, one } from "./db";
import {
  createSession,
  deviceById,
  readJson,
  rateLimit,
  requireDevice,
  requireInitialized,
  session,
  type Deps,
} from "./context";
import { insertEnvelopes, parseEnvelopes, requireAllEnvironments, verifyCert } from "./keys";
import { parsePassword } from "./auth";
import { rejectPendingPairings } from "./pairing";
import {
  bad,
  bin,
  conflict,
  decimal,
  id,
  label,
  obj,
  randomB64,
  recoveryAuthMsg,
  rootRecoveryMsg,
  str,
  unauthorized,
  verifyEd25519,
} from "./util";

export function recoveryRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

  const requireRecoverySession = async (c: Parameters<typeof session>[0]) => {
    const s = await session(c, deps);
    if (s.kind !== "recovery") throw unauthorized("恢复会话已失效，请重新输入恢复码。");
    return s;
  };

  app.post("/api/v1/recovery/challenge", async (c) => {
    rateLimit(c, deps, "recovery", 10);
    const a = requireInitialized(sql);
    const nonce = randomB64(32);
    const expiresAt = deps.now() + 2 * 60_000;
    sql.run(`INSERT INTO challenges (nonce, kind, device_id, expires_at) VALUES (?, 'recovery', NULL, ?)`, nonce, expiresAt);
    return c.json({ accountId: a.account_id, nonce, expiresAt });
  });

  app.post("/api/v1/recovery/session", async (c) => {
    rateLimit(c, deps, "recovery", 10);
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const nonce = str(body.nonce, "挑战", 64);
    const signature = bin(body.signature, "签名", 64);
    const ch = one(sql, `SELECT 1 FROM challenges WHERE nonce = ? AND kind = 'recovery' AND expires_at > ?`, nonce, deps.now());
    sql.run(`DELETE FROM challenges WHERE nonce = ?`, nonce);
    if (!ch) throw unauthorized("恢复请求已过期，请重试。");
    if (!(await verifyEd25519(a.recovery_sign_pub, recoveryAuthMsg(nonce), signature))) {
      throw unauthorized("恢复码不对，请检查后重试。");
    }
    return c.json(await createSession(deps, "recovery", null));
  });

  app.get("/api/v1/recovery/material", async (c) => {
    await requireRecoverySession(c);
    const a = requireInitialized(sql);
    const envs = sql.all<{ id: string; name: string; key_version: number }>(
      `SELECT id, name, key_version FROM environments ORDER BY created_at`,
    );
    const envelopes = sql.all<{ env_id: string; key_version: number; sealed: string; sig: string }>(
      `SELECT env_id, key_version, sealed, sig FROM envelopes WHERE recipient = 'recovery'`,
    );
    return c.json({
      rootPub: a.root_pub,
      generation: String(a.recovery_generation),
      rootEnvelope: { sealed: a.root_recovery_sealed, sig: a.root_recovery_sig },
      environments: envs.map((e) => ({ id: e.id, name: e.name, keyVersion: String(e.key_version) })),
      envelopes: envelopes.map((e) => ({ envId: e.env_id, keyVersion: String(e.key_version), sealed: e.sealed, sig: e.sig })),
    });
  });

  app.post("/api/v1/recovery/enroll", async (c) => {
    const s = await requireRecoverySession(c);
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const d = obj(body.device, "设备信息");
    const deviceId = id(d.id, "设备 ID");
    const signPub = bin(d.signPub, "签名公钥", 32);
    const boxPub = bin(d.boxPub, "加密公钥", 32);
    const cert = bin(d.cert, "设备证书", 64);
    await verifyCert(a.root_pub, deviceId, "manager", signPub, boxPub, cert);
    const rootSealed = bin(body.rootSealed, "账号密钥封装", 80);
    const envelopes = await parseEnvelopes(a.root_pub, deviceId, body.envelopes);
    const name = label(d.name, "设备名");
    const platform = label(d.platform, "平台");
    const now = deps.now();
    sql.transaction(() => {
      if (deviceById(sql, deviceId)) throw conflict("设备已存在。");
      requireAllEnvironments(sql, envelopes);
      sql.run(
        `INSERT INTO devices (id, name, platform, kind, sign_pub, box_pub, cert, root_sealed, status, rotation_required, created_at, last_seen_at)
         VALUES (?, ?, ?, 'manager', ?, ?, ?, ?, 'active', 1, ?, ?)`,
        deviceId,
        name,
        platform,
        signPub,
        boxPub,
        cert,
        rootSealed,
        now,
        now,
      );
      insertEnvelopes(sql, envelopes);
      sql.run(`DELETE FROM sessions WHERE kind = 'recovery' OR token_hash = ?`, s.tokenHash);
      bump(sql);
    });
    deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
    return c.json({ ok: true });
  });

  app.post("/api/v1/recovery/rotate", async (c) => {
    const d = await requireDevice(c, deps, { manager: true, allowRotation: true });
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const key = str(body.idempotencyKey, "操作编号", 64);
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(key)) throw bad("操作编号格式不对。");
    const done = one<{ response: string }>(sql, `SELECT response FROM idempotency WHERE device_id = ? AND key = ?`, d.id, key);
    if (done) return c.json(JSON.parse(done.response));
    const generation = decimal(body.generation, "恢复代际");
    const signPub = bin(body.signPub, "恢复签名公钥", 32);
    const boxPub = bin(body.boxPub, "恢复加密公钥", 32);
    const re = obj(body.rootEnvelope, "恢复封装");
    const rootSealed = bin(re.sealed, "恢复封装内容", 80);
    const rootSig = bin(re.sig, "恢复封装签名", 64);
    if (!(await verifyEd25519(signPub, await rootRecoveryMsg(generation, rootSealed), rootSig))) {
      throw bad("新恢复码的签名无效。");
    }
    const envelopes = await parseEnvelopes(a.root_pub, "recovery", body.envelopes);
    const password = body.password === undefined ? null : await parsePassword(body.password);
    const response = { state: "complete", generation: String(generation) };
    sql.transaction(() => {
      const cur = requireInitialized(sql);
      if (generation !== cur.recovery_generation + 1) throw conflict("恢复码已被更换过，请同步后重试。");
      requireAllEnvironments(sql, envelopes);
      sql.run(
        `UPDATE account SET recovery_generation = ?, recovery_sign_pub = ?, recovery_box_pub = ?,
          root_recovery_sealed = ?, root_recovery_sig = ? WHERE id = 1`,
        generation,
        signPub,
        boxPub,
        rootSealed,
        rootSig,
      );
      sql.run(`DELETE FROM envelopes WHERE recipient = 'recovery'`);
      insertEnvelopes(sql, envelopes);
      if (password) {
        sql.run(
          `UPDATE account SET kdf_salt = ?, auth_salt = ?, auth_hash = ? WHERE id = 1`,
          password.kdfSalt,
          password.authSalt,
          password.authHash,
        );
        sql.run(`DELETE FROM sessions WHERE kind = 'password'`);
      }
      sql.run(`UPDATE devices SET rotation_required = 0 WHERE id = ?`, d.id);
      sql.run(`DELETE FROM sessions WHERE kind = 'recovery'`);
      sql.run(`DELETE FROM challenges WHERE kind = 'recovery'`);
      sql.run(
        `INSERT INTO idempotency (device_id, key, request_hash, response, created_at) VALUES (?, ?, '', ?, ?)`,
        d.id,
        key,
        JSON.stringify(response),
        deps.now(),
      );
      bump(sql);
    });
    if (password) rejectPendingPairings(deps);
    deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
    return c.json(response);
  });

  app.get("/api/v1/recovery/rotate/:key", async (c) => {
    const d = await requireDevice(c, deps, { manager: true, allowRotation: true });
    const done = one<{ response: string }>(
      sql,
      `SELECT response FROM idempotency WHERE device_id = ? AND key = ?`,
      d.id,
      c.req.param("key"),
    );
    return c.json(done ? JSON.parse(done.response) : { state: "absent" });
  });
}
