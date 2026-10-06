// 配对：新设备发起请求，管理手机核对后批准（docs/protocol.md 3.3、5.10）。
import type { Hono } from "hono";
import { bump, headSeq, one } from "./db";
import {
  readJson,
  rateLimit,
  requireDevice,
  requireInitialized,
  session,
  sweep,
  tokenHash,
  type Deps,
} from "./context";
import { insertEnvelopes, parseEnvelopes, requireAllEnvironments, checkKeyVersions, verifyCert } from "./keys";
import { parseGrants, writeGrants } from "./grants";
import { ApiError, bad, bin, conflict, id, label, notFound, randomB64, unauthorized } from "./util";

type Pairing = {
  id: string;
  secret_hash: string;
  name: string;
  platform: string;
  sign_pub: string;
  box_pub: string;
  root_pub: string;
  status: string;
  created_at: number;
  expires_at: number;
};

const PAIRING_TTL = 10 * 60_000;

const view = (p: Pairing) => ({
  id: p.id,
  name: p.name,
  platform: p.platform,
  signPub: p.sign_pub,
  boxPub: p.box_pub,
  rootPub: p.root_pub,
  createdAt: p.created_at,
  expiresAt: p.expires_at,
});

export function pairingRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

  const pendingPairing = (pairingId: string): Pairing => {
    sweep(deps);
    const p = one<Pairing>(sql, `SELECT * FROM pairings WHERE id = ?`, pairingId);
    if (!p) throw notFound("配对请求不存在或已过期。");
    if (p.status !== "pending") throw conflict("这个配对请求已经处理过或已过期。");
    return p;
  };

  app.post("/api/v1/pairings", async (c) => {
    rateLimit(c, deps, "pairing", 10);
    const s = await session(c, deps);
    if (s.kind !== "password") throw unauthorized();
    const a = requireInitialized(sql);
    const body = await readJson(c);
    const rootPub = bin(body.rootPub, "账号公钥", 32);
    if (rootPub !== a.root_pub) {
      throw conflict("服务器返回的账号公钥与本机记录不一致，已停止配对。请确认服务器地址是否正确。");
    }
    sweep(deps);
    const pending = one<{ n: number }>(sql, `SELECT COUNT(*) AS n FROM pairings WHERE status = 'pending'`)!.n;
    if (pending >= 20) throw new ApiError(429, "rate_limited", "待处理的配对请求太多，请稍后再试。");
    const secret = randomB64(32);
    const now = deps.now();
    const p: Pairing = {
      id: randomB64(16),
      secret_hash: await tokenHash(secret),
      name: label(body.name, "设备名"),
      platform: label(body.platform, "平台"),
      sign_pub: bin(body.signPub, "签名公钥", 32),
      box_pub: bin(body.boxPub, "加密公钥", 32),
      root_pub: rootPub,
      status: "pending",
      created_at: now,
      expires_at: now + PAIRING_TTL,
    };
    sql.run(
      `INSERT INTO pairings (id, secret_hash, name, platform, sign_pub, box_pub, root_pub, status, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      p.id,
      p.secret_hash,
      p.name,
      p.platform,
      p.sign_pub,
      p.box_pub,
      p.root_pub,
      p.status,
      p.created_at,
      p.expires_at,
    );
    deps.notifier.send("managers", { type: "pairing" });
    return c.json({ id: p.id, secret, expiresAt: p.expires_at });
  });

  app.get("/api/v1/pairings/:id/status", async (c) => {
    const pairingId = id(c.req.param("id"), "配对 ID");
    const secret = c.req.header("x-pairing-secret") ?? "";
    sweep(deps);
    const p = one<Pairing>(sql, `SELECT * FROM pairings WHERE id = ?`, pairingId);
    if (!p || p.secret_hash !== (await tokenHash(secret))) throw notFound("配对请求不存在或已过期。");
    return c.json({ status: p.status });
  });

  app.get("/api/v1/pairings", async (c) => {
    await requireDevice(c, deps, { manager: true });
    sweep(deps);
    const rows = sql.all<Pairing>(`SELECT * FROM pairings WHERE status = 'pending' ORDER BY created_at DESC`);
    return c.json({ pairings: rows.map(view) });
  });

  app.get("/api/v1/pairings/:id", async (c) => {
    await requireDevice(c, deps, { manager: true });
    return c.json(view(pendingPairing(id(c.req.param("id"), "配对 ID"))));
  });

  app.post("/api/v1/pairings/:id/approve", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = requireInitialized(sql);
    const p = pendingPairing(id(c.req.param("id"), "配对 ID"));
    if (p.root_pub !== a.root_pub) throw conflict("这台设备连接的账号公钥不一致，不能批准。");
    const body = await readJson(c);
    const kind = body.kind;
    if (kind !== "client" && kind !== "manager") throw bad("设备类型不对。");
    const cert = bin(body.cert, "设备证书", 64);
    await verifyCert(a.root_pub, p.id, kind, p.sign_pub, p.box_pub, cert);
    const envelopes = await parseEnvelopes(a.root_pub, p.id, body.envelopes);
    const grants = kind === "client" ? parseGrants(body.grants) : [];
    const rootSealed = kind === "manager" ? bin(body.rootSealed, "账号密钥封装", 80) : null;
    const now = deps.now();
    sql.transaction(() => {
      pendingPairing(p.id);
      if (kind === "manager") {
        requireAllEnvironments(sql, envelopes);
      } else {
        checkKeyVersions(sql, envelopes);
        const covered = new Set(envelopes.map((e) => e.envId));
        if (grants.some((g) => !covered.has(g.envId)) || envelopes.length !== grants.length) {
          throw bad("每个授权的环境都需要对应的封装。");
        }
      }
      sql.run(
        `INSERT INTO devices (id, name, platform, kind, sign_pub, box_pub, cert, root_sealed, status, created_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
        p.id,
        p.name,
        p.platform,
        kind,
        p.sign_pub,
        p.box_pub,
        cert,
        rootSealed,
        now,
        now,
      );
      insertEnvelopes(sql, envelopes);
      const seq = bump(sql);
      writeGrants(sql, p.id, grants, seq);
      sql.run(`UPDATE pairings SET status = 'approved' WHERE id = ?`, p.id);
    });
    deps.notifier.send("all", { type: "changed", seq: headSeq(sql) });
    return c.json({ ok: true, deviceId: p.id });
  });

  app.post("/api/v1/pairings/:id/reject", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const p = pendingPairing(id(c.req.param("id"), "配对 ID"));
    sql.run(`UPDATE pairings SET status = 'rejected' WHERE id = ?`, p.id);
    return c.json({ ok: true });
  });
}
