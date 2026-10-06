// 单个账号的 HTTP 应用（运行在账号 Durable Object 内）。
import { Hono } from "hono";
import type { Deps } from "./context";
import { authRoutes } from "./auth";
import { pairingRoutes } from "./pairing";
import { dataRoutes } from "./data";
import { deviceRoutes } from "./devices";
import { recoveryRoutes } from "./recovery";
import { ApiError } from "./util";

export function errorResponse(e: unknown): Response {
  if (e instanceof ApiError) {
    return Response.json({ error: e.code, message: e.message }, { status: e.status });
  }
  console.error(e);
  return Response.json({ error: "internal", message: "服务器内部错误，请稍后再试。" }, { status: 500 });
}

export function createAccountApp(deps: Deps): Hono {
  const app = new Hono();
  authRoutes(app, deps);
  pairingRoutes(app, deps);
  dataRoutes(app, deps);
  deviceRoutes(app, deps);
  recoveryRoutes(app, deps);
  app.notFound(() => errorResponse(new ApiError(404, "not_found", "接口不存在，请确认 App 与服务器版本是否匹配。")));
  app.onError((e) => errorResponse(e));
  return app;
}
