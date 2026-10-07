// Cloudflare Workers 入口：目录 Durable Object、账号 Durable Object 与请求路由。
import { DurableObject } from "cloudflare:workers";
import { createAccountApp } from "../core/app";
import type { Deps, Device, Notifier, PairingWaiters, PushMessage, PushTarget } from "../core/context";
import { migrate, wipe, type Param, type Sql } from "../core/db";
import { Directory as DirectoryCore } from "../core/directory";
import type { Mailer } from "../core/email";
import { checkWaiters, pairingLeft } from "../core/pairing";
import { VERSION } from "../core/protocol";
import { route, type Backend } from "../core/router";

export interface Env {
  ACCOUNT: DurableObjectNamespace<Account>;
  DIRECTORY: DurableObjectNamespace<Directory>;
  EMAIL?: SendEmail;
  EMAIL_FROM?: string;
  ALLOW_REGISTRATION?: string;
  REQUIRE_EMAIL_VERIFICATION?: string;
  /** 入口总量限制（每个网络每分钟 300 次，见 wrangler.jsonc）；没有配置时跳过。 */
  LIMITER?: RateLimit;
  /** 仅本地开发：把验证码打印到日志而不是发送邮件。 */
  DEV_MAIL_LOG?: string;
}

/** 配对发起方等待连接的标签；另加 `pairing:<配对 ID>` 用于按请求查找。 */
const PAIRING_TAG = "pairing";
const WAITER_CHECK = 10_000;

function doSql(storage: DurableObjectStorage): Sql {
  return {
    all: <T>(query: string, ...params: Param[]) => storage.sql.exec(query, ...params).toArray() as T[],
    run: (query: string, ...params: Param[]) => void storage.sql.exec(query, ...params),
    transaction: <T>(fn: () => T) => storage.transactionSync(fn),
  };
}

function mailer(env: Env): Mailer {
  if (env.DEV_MAIL_LOG === "true") {
    return {
      available: true,
      send: async (message, meta) => console.log(`[harmonia dev-mail] to=${message.to} purpose=${meta.purpose} code=${meta.code}`),
    };
  }
  const binding = env.EMAIL;
  const from = env.EMAIL_FROM?.trim();
  if (!binding || !from) return { available: false, send: async () => {} };
  return {
    available: true,
    send: async (m) => {
      await binding.send({ from, to: m.to, subject: m.subject, text: m.text, ...(m.html ? { html: m.html } : {}) });
    },
  };
}

export class Account extends DurableObject<Env> {
  private sql: Sql;
  private ready = false;
  private app: ReturnType<typeof createAccountApp>;
  private deps: Deps;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = doSql(ctx.storage);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    const notifier: Notifier = {
      send: (target: PushTarget, msg: PushMessage) => {
        const tag = target === "all" ? "device" : target === "managers" ? "manager" : target.device;
        for (const ws of ctx.getWebSockets(tag)) {
          try {
            ws.send(JSON.stringify(msg));
          } catch {
            // 连接已断开时忽略。
          }
        }
      },
      disconnect: (deviceId: string) => {
        for (const ws of ctx.getWebSockets(deviceId)) ws.close(4001, "revoked");
      },
    };
    const waiters: PairingWaiters = {
      accept: (pairingId) => {
        const pair = new WebSocketPair();
        ctx.acceptWebSocket(pair[1], [PAIRING_TAG, `${PAIRING_TAG}:${pairingId}`]);
        pair[1].serializeAttachment({ pairingId, since: Date.now() });
        void ctx.storage.setAlarm(Date.now() + WAITER_CHECK);
        return new Response(null, { status: 101, webSocket: pair[0] });
      },
      waiting: (pairingId) => ctx.getWebSockets(`${PAIRING_TAG}:${pairingId}`).length > 0,
      list: () =>
        ctx.getWebSockets(PAIRING_TAG).map((ws) => {
          const a = ws.deserializeAttachment() as { pairingId: string; since: number };
          const ping = ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
          return { pairingId: a.pairingId, seenAt: Math.max(a.since, ping) };
        }),
      close: (pairingId, result) => {
        for (const ws of ctx.getWebSockets(`${PAIRING_TAG}:${pairingId}`)) {
          try {
            if (result) ws.send(JSON.stringify({ type: result }));
            ws.close(1000, result ?? "left");
          } catch {
            // 连接已断开时忽略。
          }
        }
      },
    };
    const deps: Deps = {
      sql: this.sql,
      notifier,
      waiters,
      mailer: mailer(env),
      now: () => Date.now(),
      acceptSocket: (d: Device) => {
        const pair = new WebSocketPair();
        ctx.acceptWebSocket(pair[1], ["device", d.id, d.kind]);
        return new Response(null, { status: 101, webSocket: pair[0] });
      },
    };
    this.deps = deps;
    this.app = createAccountApp(deps);
  }

  /** 未注册的账号 ID 不创建任何存储，避免被随意占用。 */
  private exists(): boolean {
    if (this.ready) return true;
    const t = this.sql.all(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'account'`);
    if (t.length) {
      migrate(this.sql);
      this.ready = true;
    }
    return this.ready;
  }

  async fetch(req: Request): Promise<Response> {
    if (!this.exists()) {
      if (new URL(req.url).pathname !== "/api/v1/register") {
        return Response.json({ error: "not_found", message: "这个账号不存在。" }, { status: 404 });
      }
      migrate(this.sql);
      this.ready = true;
    }
    return this.app.fetch(req);
  }

  async wipe(): Promise<void> {
    if (this.exists()) wipe(this.sql);
  }

  async webSocketClose(ws: WebSocket, code: number) {
    ws.close(code === 1005 ? 1000 : code, "closed");
    if (!this.ctx.getTags(ws).includes(PAIRING_TAG) || !this.exists()) return;
    const { pairingId } = ws.deserializeAttachment() as { pairingId: string };
    pairingLeft(this.deps, pairingId);
  }

  /** 有等待连接时每 10 秒检查一次心跳和请求状态。 */
  async alarm() {
    if (!this.exists()) return;
    if (checkWaiters(this.deps)) await this.ctx.storage.setAlarm(Date.now() + WAITER_CHECK);
  }

  async webSocketMessage() {}
}

export class Directory extends DurableObject<Env> {
  private core: DirectoryCore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.core = new DirectoryCore(doSql(ctx.storage), () => Date.now());
  }

  async firstCompleted() {
    return this.core.firstCompleted();
  }
  async reserve(email: string, allow: boolean) {
    return this.core.reserve(email, allow);
  }
  async activate(email: string, accountId: string, allow: boolean) {
    this.core.activate(email, accountId, allow);
  }
  async lookup(email: string) {
    return this.core.lookup(email);
  }
  async remove(email: string, accountId: string, reset?: boolean) {
    this.core.remove(email, accountId, reset);
  }
  async limit(bucket: string, ip: string | null, max: number, windowMs: number) {
    return this.core.limit(bucket, ip, max, windowMs);
  }
}

function backend(env: Env): Backend {
  const dir = env.DIRECTORY.getByName("directory");
  return {
    directory: {
      firstCompleted: () => dir.firstCompleted(),
      reserve: (email, allow) => dir.reserve(email, allow),
      activate: (email, id, allow) => dir.activate(email, id, allow),
      lookup: (email) => dir.lookup(email),
      remove: (email, id, reset) => dir.remove(email, id, reset),
      limit: (bucket, ip, max, windowMs) => dir.limit(bucket, ip, max, windowMs),
    },
    entryLimit: env.LIMITER ? async (key) => (await env.LIMITER!.limit({ key })).success : undefined,
    account: (id) => {
      const stub = env.ACCOUNT.getByName(id);
      return { fetch: (req) => stub.fetch(req), wipe: () => stub.wipe() };
    },
    config: {
      allowRegistration: env.ALLOW_REGISTRATION === "true",
      requireVerification: env.REQUIRE_EMAIL_VERIFICATION === "true",
      version: VERSION,
    },
  };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    return route(req, backend(env), req.headers.get("cf-connecting-ip") ?? "local");
  },
} satisfies ExportedHandler<Env>;
