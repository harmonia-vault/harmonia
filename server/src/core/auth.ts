// 账号生命周期（注册、验证、匿名查询、重置账号）与设备会话。运行在单个账号的 Durable Object 内。
// 账号没有密码（docs/protocol.md 3.0）：注册会话只能完成首次初始化，新设备通过配对或恢复接入。
import type { Context, Hono } from "hono";
import { bump, one, wipe } from "./db";
import {
  account,
  createSession,
  deviceById,
  readJson,
  rateLimit,
  requesterNet,
  requireAccount,
  requireDevice,
  session,
  sweep,
  type Deps,
} from "./context";
import { checkCode, sendCode } from "./email";
import { verifyCert } from "./keys";
import {
  ApiError,
  authMsg,
  bad,
  bin,
  conflict,
  decimal,
  id,
  label,
  obj,
  randomB64,
  rootRecoveryMsg,
  str,
  unauthorized,
  verifyEd25519,
} from "./util";

export function normalizeEmail(v: unknown): string {
  const s = str(v, "邮箱", 254).trim().toLowerCase();
  if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(s)) throw bad("请输入有效的邮箱地址。");
  return s;
}

/** 由 Worker 写入的内部请求头：已解析的账号 ID。 */
export const ACCOUNT_HEADER = "x-harmonia-account";
/** 由 Worker 写入的内部请求头：注册时是否需要验证邮箱。 */
export const VERIFY_HEADER = "x-harmonia-verify";

const IN_USE = "这个邮箱已经注册并完成了设置。新设备请选择接入，由管理设备批准；丢失了所有管理设备时，请用恢复码恢复。";

export function authRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

  // ---- 注册与邮箱验证 ----

  // 已注册但还没有初始化的账号没有任何数据，按新注册处理：原来的注册会话和验证码一并作废。
  app.post("/api/v1/register", async (c) => {
    const body = await readJson(c);
    const email = normalizeEmail(body.email);
    const accountId = id(c.req.header(ACCOUNT_HEADER), "账号 ID");
    const verify = c.req.header(VERIFY_HEADER) === "1";
    if (verify && !deps.mailer.available) {
      throw new ApiError(503, "email_unavailable", "服务器没有配置发信，暂时无法注册。请联系服务器管理员。");
    }
    if (account(sql)?.root_pub) throw conflict(IN_USE);
    sql.transaction(() => {
      sql.run(`DELETE FROM account`);
      sql.run(`DELETE FROM sessions`);
      sql.run(`DELETE FROM email_flows`);
      sql.run(
        `INSERT INTO account (id, account_id, email, status, created_at) VALUES (1, ?, ?, ?, ?)`,
        accountId,
        email,
        verify ? "pending" : "active",
        deps.now(),
      );
    });
    if (verify) {
      const flow = await sendCode(deps, email, "verification", await requesterNet(c, deps));
      return c.json({ accountId, verificationRequired: true, flow });
    }
    return c.json({ accountId, verificationRequired: false, ...(await createSession(deps, "registration", null)) });
  });

  // 每次都要校验验证码：注册会话只发给验证过邮箱的人。
  app.post("/api/v1/register/verify", async (c) => {
    const body = await readJson(c);
    const a = requireAccount(sql);
    if (a.root_pub) throw conflict(IN_USE);
    await checkCode(deps, "verification", body.flow, body.code);
    sql.run(`UPDATE account SET status = 'active' WHERE id = 1`);
    return c.json({ accountId: a.account_id, ...(await createSession(deps, "registration", null)) });
  });

  app.post("/api/v1/register/resend", async (c) => {
    const a = requireAccount(sql);
    if (a.status === "active") throw conflict("邮箱已经验证过了，请重新开始注册。");
    return c.json({ flow: await sendCode(deps, a.email, "verification", await requesterNet(c, deps)) });
  });

  // ---- 匿名查询账号 ----

  // 返回的 rootPub 只用于新设备钉住；服务器谎报时配对指纹对不上，管理设备批准前会发现（docs/protocol.md 2.3）。
  app.get("/api/v1/accounts/lookup", (c) => {
    const a = requireAccount(sql);
    return c.json({ accountId: a.account_id, initialized: !!a.root_pub, ...(a.root_pub ? { rootPub: a.root_pub } : {}) });
  });

  // ---- 重置账号（删除全部数据） ----

  app.post("/api/v1/account-reset/request", async (c) => {
    const a = requireAccount(sql);
    return c.json({ flow: await sendCode(deps, a.email, "reset", await requesterNet(c, deps)) });
  });

  app.post("/api/v1/account-reset/complete", async (c) => {
    const body = await readJson(c);
    requireAccount(sql);
    await checkCode(deps, "reset", body.flow, body.code);
    for (const d of sql.all<{ id: string }>(`SELECT id FROM devices`)) {
      deps.notifier.send({ device: d.id }, { type: "revoked" });
      deps.notifier.disconnect(d.id);
    }
    wipe(sql);
    return c.json({ ok: true });
  });

  // ---- 账号信息与首次初始化 ----

  app.get("/api/v1/account", async (c) => {
    const s = await session(c, deps);
    if (s.kind === "device") await requireDevice(c, deps, { allowRotation: true });
    else if (s.kind !== "registration") throw unauthorized();
    const a = requireAccount(sql);
    return c.json({
      accountId: a.account_id,
      email: a.email,
      initialized: !!a.root_pub,
      ...(a.root_pub ? { rootPub: a.root_pub } : {}),
    });
  });

  app.post("/api/v1/account/setup", async (c) => {
    const s = await session(c, deps);
    if (s.kind !== "registration") throw unauthorized("注册已过期，请重新注册。");
    const body = await readJson(c);
    const rootPub = bin(body.rootPub, "账号公钥", 32);
    const d = obj(body.device, "设备信息");
    const deviceId = id(d.id, "设备 ID");
    const signPub = bin(d.signPub, "设备签名公钥", 32);
    const boxPub = bin(d.boxPub, "设备加密公钥", 32);
    const cert = bin(d.cert, "设备证书", 64);
    await verifyCert(rootPub, deviceId, "manager", signPub, boxPub, cert);
    const rootSealed = bin(body.rootSealed, "账号密钥封装", 80);
    const r = obj(body.recovery, "恢复信息");
    if (decimal(r.generation, "恢复代际") !== 1) throw bad("首次初始化的恢复代际必须为 1。");
    const recSignPub = bin(r.signPub, "恢复签名公钥", 32);
    const recBoxPub = bin(r.boxPub, "恢复加密公钥", 32);
    const recSealed = bin(r.rootSealed, "恢复封装", 80);
    const recSig = bin(r.rootSig, "恢复封装签名", 64);
    if (!(await verifyEd25519(recSignPub, await rootRecoveryMsg(1, recSealed), recSig))) {
      throw bad("恢复封装签名无效。");
    }
    const name = label(d.name, "设备名");
    const platform = label(d.platform, "平台");
    const now = deps.now();
    sql.transaction(() => {
      if (requireAccount(sql).root_pub) throw conflict("这个账号已经完成初始化。");
      sql.run(
        `UPDATE account SET root_pub = ?, recovery_generation = 1, recovery_sign_pub = ?, recovery_box_pub = ?,
          root_recovery_sealed = ?, root_recovery_sig = ? WHERE id = 1`,
        rootPub,
        recSignPub,
        recBoxPub,
        recSealed,
        recSig,
      );
      sql.run(
        `INSERT INTO devices (id, name, platform, kind, sign_pub, box_pub, cert, root_sealed, status, created_at, last_seen_at)
         VALUES (?, ?, ?, 'manager', ?, ?, ?, ?, 'active', ?, ?)`,
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
      sql.run(`DELETE FROM sessions WHERE kind = 'registration'`);
      bump(sql);
    });
    return c.json({ ok: true });
  });

  // ---- 设备会话 ----

  app.post("/api/v1/auth/challenge", async (c) => {
    await rateLimit(c, deps, "challenge", 30);
    const deviceId = id((await readJson(c)).deviceId, "设备 ID");
    requireAccount(sql);
    const d = deviceById(sql, deviceId);
    if (!d) throw unauthorized("这台设备还没有被批准。");
    if (d.status !== "active") throw new ApiError(401, "device_revoked", "这台设备已被移除，请重新连接。");
    sweep(deps);
    const nonce = randomB64(32);
    const expiresAt = deps.now() + 2 * 60_000;
    sql.run(`INSERT INTO challenges (nonce, kind, device_id, expires_at) VALUES (?, 'device', ?, ?)`, nonce, deviceId, expiresAt);
    return c.json({ nonce, expiresAt });
  });

  app.post("/api/v1/auth/device-session", async (c: Context) => {
    const body = await readJson(c);
    const deviceId = id(body.deviceId, "设备 ID");
    const nonce = str(body.nonce, "挑战", 64);
    const signature = bin(body.signature, "签名", 64);
    const ch = one(
      sql,
      `SELECT * FROM challenges WHERE nonce = ? AND kind = 'device' AND device_id = ? AND expires_at > ?`,
      nonce,
      deviceId,
      deps.now(),
    );
    sql.run(`DELETE FROM challenges WHERE nonce = ?`, nonce);
    if (!ch) throw unauthorized("登录挑战已过期，请重试。");
    const d = deviceById(sql, deviceId);
    if (!d) throw unauthorized();
    if (d.status !== "active") throw new ApiError(401, "device_revoked", "这台设备已被移除，请重新连接。");
    if (!(await verifyEd25519(d.sign_pub, authMsg(deviceId, nonce), signature))) throw unauthorized("设备签名无效。");
    sql.run(`UPDATE devices SET last_seen_at = ? WHERE id = ?`, deps.now(), deviceId);
    return c.json(await createSession(deps, "device", deviceId));
  });
}
