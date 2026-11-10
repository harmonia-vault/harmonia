// Cloudflare Workers 入口：全部请求交给唯一的 Durable Object。
import { DurableObject } from "cloudflare:workers";
import { Apns } from "../core/apns";
import { createRelayApp } from "../core/app";
import { migrate, one, type Param, type Sql } from "../core/db";
import { Fcm, parseServiceAccount } from "../core/fcm";
import { Registry as RegistryCore, LIMITS } from "../core/registry";
import { platformSender, type Sender } from "../core/sender";
import { randomB64 } from "../core/util";

export interface Env {
  REGISTRY: DurableObjectNamespace<Registry>;
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /** App 的 bundle ID。 */
  APNS_TOPIC?: string;
  /** FCM 服务账号的 JSON。 */
  FCM_SERVICE_ACCOUNT?: string;
  /** 全局每分钟最多发出的通知条数，默认 1000（docs/protocol.md 5.3）。 */
  NOTIFY_GLOBAL_PER_MINUTE?: string;
  /** 仅本地开发：不连接 APNs、FCM，把要发的通知写进日志。部署时不要设置。 */
  DEV_FAKE_SENDER?: string;
}

function doSql(storage: DurableObjectStorage): Sql {
  return {
    all: <T>(query: string, ...params: Param[]) => storage.sql.exec(query, ...params).toArray() as T[],
    run: (query: string, ...params: Param[]) => void storage.sql.exec(query, ...params),
    transaction: <T>(fn: () => T) => storage.transactionSync(fn),
  };
}

function sender(env: Env): Sender {
  if (env.DEV_FAKE_SENDER === "true") {
    return {
      send: async (reg, msg) => {
        console.log(`[harmonia dev-push] platform=${reg.platform} type=${msg.type} token=${reg.token}`);
        return "ok";
      },
    };
  }
  const ios =
    env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC
      ? new Apns({ key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC })
      : undefined;
  const android = env.FCM_SERVICE_ACCOUNT ? new Fcm(parseServiceAccount(env.FCM_SERVICE_ACCOUNT)) : undefined;
  return platformSender({ ios, android });
}

export class Registry extends DurableObject<Env> {
  private app: ReturnType<typeof createRelayApp>;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = doSql(ctx.storage);
    migrate(sql);
    const perMinute = Number(env.NOTIFY_GLOBAL_PER_MINUTE);
    const registry = new RegistryCore(sql, () => Date.now(), perMinute > 0 ? perMinute : LIMITS.defaultGlobalPerMinute);
    this.app = createRelayApp({
      registry,
      sender: sender(env),
      networkSecret: () => {
        const row = one<{ value: string }>(sql, `SELECT value FROM kv WHERE key = 'network_secret'`);
        if (row) return row.value;
        const secret = randomB64(32);
        sql.run(`INSERT INTO kv (key, value) VALUES ('network_secret', ?)`, secret);
        return secret;
      },
    });
  }

  async fetch(req: Request): Promise<Response> {
    return this.app.fetch(req);
  }
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    return env.REGISTRY.getByName("registry").fetch(req);
  },
} satisfies ExportedHandler<Env>;
