// 测试工具：node:sqlite 存储、内存路由后端，以及模拟客户端的签名操作。
import { DatabaseSync } from "node:sqlite";
import { expect } from "vitest";
import { createAccountApp } from "../src/core/app";
import type { Deps, PairingResult, PairingWaiters, PushMessage, PushTarget } from "../src/core/context";
import { migrate, wipe, type Param, type Sql } from "../src/core/db";
import { Directory } from "../src/core/directory";
import { route, type Backend } from "../src/core/router";
import { authMsg, b64, canonical, deviceCertMsg, envelopeMsg, recoveryAuthMsg, rootRecoveryMsg } from "../src/core/util";

export function nodeSql(): Sql {
  const db = new DatabaseSync(":memory:");
  let depth = 0;
  return {
    all: <T>(q: string, ...p: Param[]) => db.prepare(q).all(...p) as T[],
    run: (q: string, ...p: Param[]) => void db.prepare(q).run(...p),
    transaction: <T>(fn: () => T): T => {
      if (depth > 0) return fn();
      depth++;
      db.exec("BEGIN");
      try {
        const r = fn();
        db.exec("COMMIT");
        return r;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      } finally {
        depth--;
      }
    },
  };
}

export type Sent = { target: PushTarget; msg: PushMessage; account: string };

/** 内存中的配对等待连接：记录最近心跳时间和发给发起方的结果。 */
export class FakeWaiters implements PairingWaiters {
  open = new Map<string, number>();
  results = new Map<string, PairingResult | "left">();
  constructor(private now: () => number) {}
  accept(pairingId: string) {
    this.open.set(pairingId, this.now());
    return Response.json({ ok: true });
  }
  waiting(pairingId: string) {
    return this.open.has(pairingId);
  }
  list() {
    return [...this.open].map(([pairingId, seenAt]) => ({ pairingId, seenAt }));
  }
  close(pairingId: string, result?: PairingResult) {
    if (this.open.delete(pairingId)) this.results.set(pairingId, result ?? "left");
  }
  ping(pairingId: string) {
    this.open.set(pairingId, this.now());
  }
}

export class TestServer {
  clock = 1_800_000_000_000;
  mails: { to: string; purpose: string; code: string }[] = [];
  pushes: Sent[] = [];
  config = { allowRegistration: false, requireVerification: true, version: "0.1.0" };
  mailAvailable = true;
  private dir = new Directory(nodeSql(), () => this.clock);
  private accounts = new Map<string, { deps: Deps; app: ReturnType<typeof createAccountApp> }>();

  /** 账号的依赖（用于直接调用定时检查等非 HTTP 入口）。 */
  deps(accountId: string): Deps {
    return this.account(accountId).deps;
  }

  waiters(accountId: string): FakeWaiters {
    return this.deps(accountId).waiters as FakeWaiters;
  }

  private account(id: string) {
    let a = this.accounts.get(id);
    if (!a) {
      const sql = nodeSql();
      migrate(sql);
      const deps: Deps = {
        sql,
        now: () => this.clock,
        notifier: {
          send: (target, msg) => this.pushes.push({ target, msg, account: id }),
          disconnect: () => {},
        },
        waiters: new FakeWaiters(() => this.clock),
        mailer: {
          get available() {
            return server.mailAvailable;
          },
          send: async (m, meta) => void this.mails.push({ to: m.to, ...meta }),
        },
      };
      const server = this;
      a = { deps, app: createAccountApp(deps) };
      this.accounts.set(id, a);
    }
    return a;
  }

  backend(): Backend {
    const d = this.dir;
    return {
      directory: {
        firstCompleted: async () => d.firstCompleted(),
        reserve: async (e, a) => d.reserve(e, a),
        activate: async (e, i, a) => d.activate(e, i, a),
        lookup: async (e) => d.lookup(e),
        remove: async (e, i, r) => d.remove(e, i, r),
        allow: async (k, m) => d.allow(k, m),
      },
      account: (id) => ({
        fetch: async (req) => this.account(id).app.fetch(req),
        wipe: async () => wipe(this.account(id).deps.sql),
      }),
      config: this.config,
    };
  }

  lastCode(purpose: string): string {
    const m = [...this.mails].reverse().find((x) => x.purpose === purpose);
    if (!m) throw new Error(`没有 ${purpose} 邮件`);
    return m.code;
  }

  async call(method: string, path: string, opts: { body?: unknown; token?: string; headers?: Record<string, string> } = {}) {
    const headers: Record<string, string> = { "content-type": "application/json", ...opts.headers };
    if (opts.token) headers.authorization = `Bearer ${opts.token}`;
    const req = new Request(`http://localhost${path}`, {
      method,
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
    const res = await route(req, this.backend(), `ip-${Math.random()}`);
    const json = (await res.json()) as Record<string, any>;
    return { status: res.status, json };
  }

  async ok(method: string, path: string, opts: Parameters<TestServer["call"]>[2] = {}) {
    const r = await this.call(method, path, opts);
    if (r.status !== 200) throw new Error(`${method} ${path} → ${r.status} ${JSON.stringify(r.json)}`);
    return r.json;
  }
}

// ---- 客户端侧密码学（测试用） ----

export const rand = (n: number) => crypto.getRandomValues(new Uint8Array(n));
export const newId = () => b64(rand(16));

export class Ed {
  private constructor(
    private key: CryptoKey,
    readonly pub: string,
  ) {}
  static async create(): Promise<Ed> {
    const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const raw = new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer);
    return new Ed(kp.privateKey, b64(raw));
  }
  async sign(msg: Uint8Array): Promise<string> {
    return b64(new Uint8Array(await crypto.subtle.sign("Ed25519", this.key, msg)));
  }
}

/** 一台模拟设备：签名钥 + 伪造的加密公钥（服务端不解封装）。 */
export class FakeDevice {
  id = newId();
  boxPub = b64(rand(32));
  token = "";
  private constructor(readonly sign: Ed) {}
  static async create() {
    return new FakeDevice(await Ed.create());
  }
  async login(s: TestServer, accountId: string) {
    const h = { "x-harmonia-account": accountId };
    const { nonce } = await s.ok("POST", "/api/v1/auth/challenge", { body: { deviceId: this.id }, headers: h });
    const signature = await this.sign.sign(authMsg(this.id, nonce));
    const r = await s.ok("POST", "/api/v1/auth/device-session", {
      body: { deviceId: this.id, nonce, signature },
      headers: h,
    });
    this.token = r.token;
    return r;
  }
}

/** 已注册并在手机上初始化完成的账号。 */
export class TestAccount {
  email = "";
  accountId = "";
  authKey = b64(rand(32));
  kdfSalt = b64(rand(16));
  root!: Ed;
  recovery!: Ed;
  phone!: FakeDevice;

  static async create(s: TestServer, email = `u${Math.random().toString(36).slice(2)}@example.com`) {
    const a = new TestAccount();
    a.email = email;
    const reg = await s.ok("POST", "/api/v1/register", { body: { email, kdfSalt: a.kdfSalt, authKey: a.authKey } });
    a.accountId = reg.accountId;
    if (reg.verificationRequired) {
      await s.ok("POST", "/api/v1/register/verify", { body: { email, code: s.lastCode("verification") } });
    }
    const login = await a.passwordLogin(s);
    a.root = await Ed.create();
    a.recovery = await Ed.create();
    a.phone = await FakeDevice.create();
    const recSealed = b64(rand(80));
    await s.ok("POST", "/api/v1/account/setup", {
      token: login.token,
      body: {
        rootPub: a.root.pub,
        device: {
          id: a.phone.id,
          name: "测试手机",
          platform: "android",
          signPub: a.phone.sign.pub,
          boxPub: a.phone.boxPub,
          cert: await a.root.sign(deviceCertMsg(a.phone.id, "manager", a.phone.sign.pub, a.phone.boxPub)),
        },
        rootSealed: b64(rand(80)),
        recovery: {
          generation: "1",
          signPub: a.recovery.pub,
          boxPub: b64(rand(32)),
          rootSealed: recSealed,
          rootSig: await a.recovery.sign(await rootRecoveryMsg(1, recSealed)),
        },
      },
    });
    await a.phone.login(s, a.accountId);
    return a;
  }

  async passwordLogin(s: TestServer) {
    return s.ok("POST", "/api/v1/auth/login", { body: { email: this.email, authKey: this.authKey } });
  }

  async envelope(envId: string, recipient: string, keyVersion = 1) {
    const sealed = b64(rand(80));
    return { envId, recipient, keyVersion: String(keyVersion), sealed, sig: await this.root.sign(await envelopeMsg(envId, keyVersion, recipient, sealed)) };
  }

  async cert(d: FakeDevice, kind: string) {
    return this.root.sign(deviceCertMsg(d.id, kind, d.sign.pub, d.boxPub));
  }

  /** 由管理设备创建环境，封装给全部管理设备和恢复钥。 */
  async createEnv(s: TestServer, managers: string[], name = "OpenAI") {
    const id = newId();
    const envelopes = [];
    for (const r of [...managers, "recovery"]) envelopes.push(await this.envelope(id, r));
    await s.ok("POST", "/api/v1/environments", { token: this.phone.token, body: { id, name, envelopes } });
    return id;
  }

  async recoveryAuth(nonce: string) {
    return this.recovery.sign(recoveryAuthMsg(nonce));
  }
}

/** 发起方连上等待连接（docs/protocol.md 3.5.1）。 */
export async function waitApproval(s: TestServer, a: TestAccount, req: Record<string, any>) {
  return s.call("GET", `/api/v1/pairings/${req.id}/events`, {
    headers: { "x-harmonia-account": a.accountId, "x-pairing-secret": req.secret, upgrade: "websocket" },
  });
}

/** 电脑发起配对并由手机以指定授权批准。 */
export async function pairClient(s: TestServer, a: TestAccount, grants: { envId: string; role: string; expiresAt?: number }[]) {
  const cli = await FakeDevice.create();
  const pw = await a.passwordLogin(s);
  const req = await s.ok("POST", "/api/v1/pairings", {
    token: pw.token,
    body: { name: "笔记本", platform: "darwin", signPub: cli.sign.pub, boxPub: cli.boxPub, rootPub: a.root.pub, canManage: false },
  });
  cli.id = req.id;
  await waitApproval(s, a, req);
  const list = await s.ok("GET", "/api/v1/pairings", { token: a.phone.token });
  expect(list.pairings.map((p: { id: string }) => p.id)).toContain(req.id);
  const envelopes = [];
  for (const g of grants) envelopes.push(await a.envelope(g.envId, cli.id));
  await s.ok("POST", `/api/v1/pairings/${req.id}/approve`, {
    token: a.phone.token,
    body: { kind: "client", cert: await a.cert(cli, "client"), grants: grants.map((g) => ({ expiresAt: 0, ...g })), envelopes },
  });
  const st = await s.ok("GET", `/api/v1/pairings/${req.id}/status`, {
    headers: { "x-harmonia-account": a.accountId, "x-pairing-secret": req.secret },
  });
  expect(st.status).toBe("approved");
  await cli.login(s, a.accountId);
  return cli;
}

export { canonical };
