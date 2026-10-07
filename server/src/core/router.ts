// 入口路由：把请求交给目录或对应账号（docs/protocol.md 3.0）。Workers 与测试共用。
import { errorResponse } from "./app";
import { ACCOUNT_HEADER, normalizeEmail, VERIFY_HEADER } from "./auth";
import type { Entry } from "./directory";
import { network } from "./net";
import { PROTOCOL } from "./protocol";
import { ApiError, bad, notFound, obj, rateLimited } from "./util";

export interface DirectoryApi {
  firstCompleted(): Promise<boolean>;
  reserve(email: string, allowRegistration: boolean): Promise<string>;
  activate(email: string, accountId: string, allowRegistration: boolean): Promise<void>;
  lookup(email: string): Promise<Entry | null>;
  remove(email: string, accountId: string, reset?: boolean): Promise<void>;
  /** 按网络的限流；ip 为 null 时整个实例共用一个计数。允许时返回 0，否则返回还要等的毫秒数。 */
  limit(bucket: string, ip: string | null, max: number, windowMs: number): Promise<number>;
}

export interface Backend {
  directory: DirectoryApi;
  /** 把请求转交给账号；wipe=true 时清空该账号（注册竞争失败时使用）。 */
  account(accountId: string): { fetch(req: Request): Promise<Response>; wipe(): Promise<void> };
  config: { allowRegistration: boolean; requireVerification: boolean; version: string };
  /** 入口总量限制（每个网络每分钟 300 次），在进入 Durable Object 之前执行；没有配置时跳过。 */
  entryLimit?(key: string): Promise<boolean>;
}

const EMAIL_ROUTES = new Set([
  "/api/v1/register",
  "/api/v1/register/verify",
  "/api/v1/register/resend",
  "/api/v1/auth/prelogin",
  "/api/v1/auth/login",
  "/api/v1/password-reset/request",
  "/api/v1/password-reset/complete",
  "/api/v1/account-reset/request",
  "/api/v1/account-reset/complete",
  "/api/v1/recovery/challenge",
]);

const LIMITS: Record<string, number> = {
  "/api/v1/register": 10,
  "/api/v1/auth/login": 10,
  "/api/v1/recovery/challenge": 10,
};

const HOUR = 60 * 60_000;

/** 注册验证邮件发往尚未注册的邮箱，由目录统一限制：每个网络每小时 3 封，整个实例每天 100 封。 */
async function signupMailLimit(directory: DirectoryApi, clientIp: string) {
  const wait =
    (await directory.limit("signup-mail", clientIp, 3, HOUR)) || (await directory.limit("signup-mail", null, 100, 24 * HOUR));
  if (wait) throw rateLimited("验证码发送次数过多，请稍后再试；已经收到的验证码 15 分钟内仍然有效。", wait);
}

function forward(req: Request, body: string | null, headers: Record<string, string>): Request {
  const h = new Headers(req.headers);
  h.delete(ACCOUNT_HEADER);
  h.delete(VERIFY_HEADER);
  for (const [k, v] of Object.entries(headers)) h.set(k, v);
  return new Request(req.url, { method: req.method, headers: h, body: body ?? undefined });
}

function accountFromRequest(req: Request): string | null {
  const auth = /^Bearer ([A-Za-z0-9_-]{22})\./.exec(req.headers.get("authorization") ?? "");
  const id = auth?.[1] ?? req.headers.get("x-harmonia-account");
  return id && /^[A-Za-z0-9_-]{22}$/.test(id) ? id : null;
}

export async function route(req: Request, backend: Backend, clientIp: string): Promise<Response> {
  try {
    const url = new URL(req.url);
    // 本地开发：本机与 Android 模拟器访问宿主机的 10.0.2.2。
    const local = ["localhost", "127.0.0.1", "[::1]", "10.0.2.2"].includes(url.hostname);
    if (url.protocol !== "https:" && !local) throw bad("只允许通过 HTTPS 访问。");
    const path = url.pathname;
    const { directory, config } = backend;
    if (backend.entryLimit && !(await backend.entryLimit(network(clientIp)))) {
      throw rateLimited("请求太频繁，请稍后再试。", 60_000);
    }

    if (path === "/api/v1/instance") {
      const firstCompleted = await directory.firstCompleted();
      return Response.json({
        product: "harmonia",
        version: config.version,
        protocol: PROTOCOL,
        registration: { open: config.allowRegistration || !firstCompleted, emailVerification: config.requireVerification },
      });
    }

    if (EMAIL_ROUTES.has(path)) {
      const wait = await directory.limit(path, clientIp, LIMITS[path] ?? 20, 60_000);
      if (wait) throw rateLimited("操作太频繁，请稍后再试。", wait);
      const body = req.method === "GET" ? null : await req.text();
      let parsed: Record<string, unknown> = {};
      if (body !== null) {
        try {
          parsed = obj(JSON.parse(body));
        } catch {
          throw bad("请求内容不是有效的 JSON。");
        }
      }
      const email = normalizeEmail(req.method === "GET" ? url.searchParams.get("email") : parsed.email);

      if ((path === "/api/v1/register" && config.requireVerification) || path === "/api/v1/register/resend") {
        await signupMailLimit(directory, clientIp);
      }

      if (path === "/api/v1/register") {
        const accountId = await directory.reserve(email, config.allowRegistration);
        const verify = config.requireVerification ? "1" : "0";
        const res = await backend.account(accountId).fetch(forward(req, body, { [ACCOUNT_HEADER]: accountId, [VERIFY_HEADER]: verify }));
        if (res.ok && !config.requireVerification) await activateOrWipe(backend, email, accountId);
        return res;
      }

      const entry = await directory.lookup(email);
      if (!entry) throw notFound("这个邮箱还没有注册。");
      if (path !== "/api/v1/register/verify" && path !== "/api/v1/register/resend" && path !== "/api/v1/auth/login" &&
          path !== "/api/v1/auth/prelogin" && entry.status !== "active") {
        throw new ApiError(403, "email_unverified", "邮箱还没有验证，请先完成邮箱验证。");
      }
      const res = await backend.account(entry.accountId).fetch(forward(req, body, { [ACCOUNT_HEADER]: entry.accountId }));
      if (res.ok && path === "/api/v1/register/verify") await activateOrWipe(backend, email, entry.accountId);
      if (res.ok && path === "/api/v1/account-reset/complete") await directory.remove(email, entry.accountId, true);
      return res;
    }

    if (!path.startsWith("/api/v1/")) throw notFound("接口不存在。");
    const accountId = accountFromRequest(req);
    if (!accountId) throw new ApiError(401, "unauthorized", "请先登录。");
    return await backend.account(accountId).fetch(forward(req, req.body ? await req.text() : null, { [ACCOUNT_HEADER]: accountId }));
  } catch (e) {
    return errorResponse(e);
  }
}

async function activateOrWipe(backend: Backend, email: string, accountId: string) {
  try {
    await backend.directory.activate(email, accountId, backend.config.allowRegistration);
  } catch (e) {
    await backend.account(accountId).wipe();
    await backend.directory.remove(email, accountId);
    throw e;
  }
}
