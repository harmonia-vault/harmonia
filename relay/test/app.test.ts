import { describe, expect, it } from "vitest";
import { createRelayApp } from "../src/core/app";
import type { Message } from "../src/core/messages";
import { Registry, type Registration } from "../src/core/registry";
import type { SendResult } from "../src/core/sender";
import { nodeSql } from "./helpers";

function setup() {
  const sent: { reg: Registration; msg: Message }[] = [];
  const state = { result: "ok" as SendResult, now: 1_800_000_000_000 };
  const app = createRelayApp({
    registry: new Registry(nodeSql(), () => state.now),
    sender: { send: async (reg, msg) => (sent.push({ reg, msg }), state.result) },
    networkSecret: () => "secret",
  });
  const call = (method: string, path: string, body?: unknown, handle?: string) =>
    app.request(`https://harmonia-push.zzz.sd${path}`, {
      method,
      headers: { "content-type": "application/json", ...(handle ? { authorization: `Bearer ${handle}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  return { sent, state, call };
}

describe("中继接口", () => {
  it("登记 → 发通知 → 删除", async () => {
    const { sent, call } = setup();
    const res = await call("POST", "/api/v1/registrations", { platform: "android", token: "tok" });
    expect(res.status).toBe(200);
    const { handle } = (await res.json()) as { handle: string };

    expect((await call("POST", "/api/v1/notify", { type: "approval" }, handle)).status).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.msg.type).toBe("approval");
    // 10 秒内同一类：合并，照常成功，不再发送
    expect((await call("POST", "/api/v1/notify", { type: "approval" }, handle)).status).toBe(200);
    expect(sent).toHaveLength(1);

    expect((await call("DELETE", "/api/v1/registration", undefined, handle)).status).toBe(200);
    const gone = await call("POST", "/api/v1/notify", { type: "pairing" }, handle);
    expect(gone.status).toBe(404);
    expect(((await gone.json()) as { error: string }).error).toBe("not_found");
  });

  it("推送令牌失效时答复 not_found 并删除登记；暂时失败答复 internal", async () => {
    const { state, call } = setup();
    const { handle } = (await (await call("POST", "/api/v1/registrations", { platform: "android", token: "tok" })).json()) as { handle: string };
    state.result = "failed";
    expect((await call("POST", "/api/v1/notify", { type: "approval" }, handle)).status).toBe(503);
    state.result = "gone";
    expect((await call("POST", "/api/v1/notify", { type: "pairing" }, handle)).status).toBe(404);
    expect((await call("PUT", "/api/v1/registration", { token: "x" }, handle)).status).toBe(404);
  });

  it("实例不能指定文字，只能传类型；句柄只能放在请求头里", async () => {
    const { call } = setup();
    const { handle } = (await (await call("POST", "/api/v1/registrations", { platform: "android", token: "tok" })).json()) as { handle: string };
    expect((await call("POST", "/api/v1/notify", { type: "custom", body: "hi" }, handle)).status).toBe(400);
    expect((await call("POST", "/api/v1/notify", { type: "approval", handle })).status).toBe(400);
    expect((await call("POST", "/api/v1/notify", { type: "approval" }, "short")).status).toBe(400);
  });

  it("只允许 HTTPS（本机开发除外）", async () => {
    const { call } = setup();
    expect((await call("POST", "/api/v1/registrations", { platform: "web", token: "t" })).status).toBe(400);
    const app = createRelayApp({ registry: new Registry(nodeSql(), () => 0), sender: { send: async () => "ok" }, networkSecret: () => "s" });
    expect((await app.request("http://harmonia-push.zzz.sd/api/v1/registrations", { method: "POST", body: "{}" })).status).toBe(400);
    const local = await app.request("http://localhost:8788/api/v1/registrations", { method: "POST", body: JSON.stringify({ platform: "android", token: "t" }) });
    expect(local.status).toBe(200);
  });
});
