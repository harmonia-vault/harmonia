// 中继的 HTTP 接口（docs/protocol.md 第 5 节）。运行在唯一的 Durable Object 里，全部状态都在一处。
import { Hono, type Context } from "hono";
import { message } from "./messages";
import { networkId } from "./net";
import { parseRegistration, type Registry } from "./registry";
import type { Sender } from "./sender";
import { ApiError, bad, errorResponse, HANDLE_PATTERN, notFound, obj } from "./util";

export type RelayDeps = {
  registry: Registry;
  sender: Sender;
  /** 计算网络标识用的密钥（只保存 HMAC）。 */
  networkSecret(): string;
};

async function readJson(c: Context): Promise<Record<string, unknown>> {
  const text = await c.req.text();
  if (text.length > 8192) throw new ApiError(413, "invalid_request", "请求内容过大。");
  try {
    return obj(JSON.parse(text || "{}"));
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw bad("请求内容不是有效的 JSON。");
  }
}

/** 句柄只放在 Authorization 请求头里，不进路径，免得出现在日志中。 */
function handleOf(c: Context): string {
  const m = /^Bearer (\S+)$/.exec(c.req.header("authorization") ?? "");
  if (!m || !HANDLE_PATTERN.test(m[1]!)) throw bad("缺少句柄，或句柄格式不对。");
  return m[1]!;
}

export function createRelayApp(deps: RelayDeps): Hono {
  const app = new Hono();

  app.use(async (c, next) => {
    const url = new URL(c.req.url);
    const local = ["localhost", "127.0.0.1", "[::1]", "10.0.2.2"].includes(url.hostname);
    if (url.protocol !== "https:" && !local) throw bad("只允许通过 HTTPS 访问。");
    await next();
  });

  app.post("/api/v1/registrations", async (c) => {
    const body = await readJson(c);
    const reg = parseRegistration(body, body.platform);
    const net = await networkId(deps.networkSecret(), c.req.header("cf-connecting-ip") ?? "local");
    return c.json({ handle: await deps.registry.register(reg, net) });
  });

  app.put("/api/v1/registration", async (c) => {
    await deps.registry.confirm(handleOf(c), await readJson(c));
    return c.json({});
  });

  app.delete("/api/v1/registration", async (c) => {
    await deps.registry.remove(handleOf(c));
    return c.json({});
  });

  app.post("/api/v1/notify", async (c) => {
    const handle = handleOf(c);
    const msg = message((await readJson(c)).type);
    if (!msg) throw bad("type 只能是 approval 或 pairing。");
    const claimed = await deps.registry.claim(handle, msg.type);
    // 10 秒内已经发过同一类：手机上同一类通知只显示一条，合并掉也照常答复成功。
    if (!claimed) return c.json({});
    const result = await deps.sender.send(claimed.reg, msg);
    if (result === "gone") {
      deps.registry.forget(claimed.hash);
      throw notFound("这台手机的推送令牌已失效，请在 App 中重新开启后台通知。");
    }
    if (result === "failed") throw new ApiError(503, "internal", "推送服务暂时不可用，请稍后再试。");
    return c.json({});
  });

  app.notFound(() => errorResponse(notFound("接口不存在。")));
  app.onError((e) => errorResponse(e));
  return app;
}
