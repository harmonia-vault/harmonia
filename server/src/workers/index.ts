// Cloudflare Workers 入口：目录 Durable Object、账号 Durable Object 与请求路由。
import { DurableObject } from "cloudflare:workers";
import { createAccountApp } from "../core/app";
import type { Deps, Device, Notifier, PushMessage, PushTarget } from "../core/context";
import { migrate, wipe, type Param, type Sql } from "../core/db";
import { Directory as DirectoryCore } from "../core/directory";
import type { Mailer } from "../core/email";
import { VERSION } from "../core/protocol";
import { route, type Backend } from "../core/router";

export interface Env {
  ACCOUNT: DurableObjectNamespace<Account>;
  DIRECTORY: DurableObjectNamespace<Directory>;
  EMAIL?: SendEmail;
  EMAIL_FROM?: string;
  ALLOW_REGISTRATION?: string;
  REQUIRE_EMAIL_VERIFICATION?: string;
  /** 仅本地开发：把验证码打印到日志而不是发送邮件。 */
  DEV_MAIL_LOG?: string;
}

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

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = doSql(ctx.storage);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    const notifier: Notifier = {
      send: (target: PushTarget, msg: PushMessage) => {
        const tag = target === "all" ? undefined : target === "managers" ? "manager" : target.device;
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
    const deps: Deps = {
      sql: this.sql,
      notifier,
      mailer: mailer(env),
      now: () => Date.now(),
      acceptSocket: (d: Device) => {
        const pair = new WebSocketPair();
        ctx.acceptWebSocket(pair[1], [d.id, d.kind]);
        return new Response(null, { status: 101, webSocket: pair[0] });
      },
    };
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
  async allow(key: string, max: number) {
    return this.core.allow(key, max);
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
      allow: (key, max) => dir.allow(key, max),
    },
    account: (id) => {
      const stub = env.ACCOUNT.getByName(id);
      return { fetch: (req) => stub.fetch(req), wipe: () => stub.wipe() };
    },
    config: {
      allowRegistration: env.ALLOW_REGISTRATION === "true",
      requireVerification: env.REQUIRE_EMAIL_VERIFICATION !== "false",
      version: VERSION,
    },
  };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    return route(req, backend(env), req.headers.get("cf-connecting-ip") ?? "local");
  },
} satisfies ExportedHandler<Env>;
