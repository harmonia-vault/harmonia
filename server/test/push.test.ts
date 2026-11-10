import { describe, expect, it } from "vitest";
import { relayClient } from "../src/core/push";
import { newId, pairClient, requestPairing, TestAccount, TestServer, waitApproval } from "./helpers";
import { approvalRequestMsg, b64 } from "../src/core/util";
import { rand, type FakeDevice } from "./helpers";

const HANDLE = "h".repeat(43);

async function setup() {
  const s = new TestServer();
  const a = await TestAccount.create(s);
  await s.ok("PUT", "/api/v1/devices/self/push", { token: a.phone.token, body: { handle: HANDLE } });
  return { s, a };
}

/** 电脑发起一个读取请求并连上等待连接。 */
async function approvalRequest(s: TestServer, cli: FakeDevice, env: string) {
  const id = newId();
  const detail = JSON.stringify({
    kind: "read",
    deviceId: cli.id,
    createdAt: s.clock,
    ephPub: b64(rand(32)),
    command: "npm run dev",
    cwd: "/home/me",
    items: [{ environmentId: env, name: "TOKEN" }],
  });
  const sig = await cli.sign.sign(await approvalRequestMsg(id, cli.id, detail, ""));
  await s.ok("POST", "/api/v1/approvals", { token: cli.token, body: { id, detail, sig } });
  await s.ok("GET", `/api/v1/approvals/${id}/events`, { token: cli.token, headers: { upgrade: "websocket" } });
  await s.flush();
}

describe("推送句柄", () => {
  it("只有管理设备能登记；格式不对时拒绝；新句柄替换旧句柄并通知中继删除旧的", async () => {
    const { s, a } = await setup();
    expect((await s.call("PUT", "/api/v1/devices/self/push", { token: a.phone.token, body: { handle: "short" } })).status).toBe(400);
    const other = "o".repeat(43);
    await s.ok("PUT", "/api/v1/devices/self/push", { token: a.phone.token, body: { handle: other } });
    await s.flush();
    expect(s.relay.removed).toEqual([HANDLE]);

    const env = await a.createEnv(s, [a.phone.id]);
    const cli = await pairClient(s, a, [{ environmentId: env, role: "ro" }]);
    expect((await s.call("PUT", "/api/v1/devices/self/push", { token: cli.token, body: { handle: HANDLE } })).json.error).toBe("forbidden");
  });

  it("服务器关闭后台通知时拒绝登记，GET /instance 返回 push:false", async () => {
    const s = new TestServer();
    s.config.push = false;
    const a = await TestAccount.create(s);
    const r = await s.call("PUT", "/api/v1/devices/self/push", { token: a.phone.token, body: { handle: HANDLE } });
    expect(r.status).toBe(403);
    expect(r.json.message).toBe("这台服务器关闭了后台通知");
    expect((await s.ok("GET", "/api/v1/instance")).push).toBe(false);
    s.config.push = true;
    expect((await s.ok("GET", "/api/v1/instance")).push).toBe(true);
  });

  it("句柄不出现在同步和设备列表里", async () => {
    const { s, a } = await setup();
    const sync = await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
    expect(JSON.stringify(sync)).not.toContain(HANDLE);
  });
});

describe("什么时候发", () => {
  it.each([false, true])("新的批准请求连上等待连接时通知管理设备，包括推送连接在线时（在线：%s）", async (online) => {
    const { s, a } = await setup();
    const env = await a.createEnv(s, [a.phone.id]);
    await s.ok("PUT", `/api/v1/vaults/${env}/variables/TOKEN`, {
      token: a.phone.token,
      body: { value: b64(rand(60)), keyVersion: "1" },
      headers: { "idempotency-key": newId() },
    });
    const cli = await pairClient(s, a, [{ environmentId: env, role: "ro", localDecrypt: false }], []);
    s.relay.sent = [];
    if (online) s.online.add(a.phone.id);
    await approvalRequest(s, cli, env);
    expect(s.relay.sent).toEqual([{ handle: HANDLE, type: "approval" }]);
  });

  it.each([false, true])("用配对码发起的配对请求通知，匿名请求不通知，包括推送连接在线时（在线：%s）", async (online) => {
    const { s, a } = await setup();
    if (online) s.online.add(a.phone.id);
    const anon = await requestPairing(s, a);
    await waitApproval(s, a, anon.json);
    await s.flush();
    expect(s.relay.sent).toEqual([]);

    const r = await requestPairing(s, a, { code: await a.pairingCode(s) });
    await waitApproval(s, a, r.json);
    await s.flush();
    expect(s.relay.sent).toEqual([{ handle: HANDLE, type: "pairing" }]);
  });

  it("跳过需要轮换恢复码的设备，以及关闭了后台通知的服务器", async () => {
    const { s, a } = await setup();
    const codes = [await a.pairingCode(s), await a.pairingCode(s), await a.pairingCode(s)];
    const code = async () => {
      const r = await requestPairing(s, a, { code: codes.pop()! });
      await waitApproval(s, a, r.json);
      await s.flush();
    };
    s.deps(a.accountId).sql.run(`UPDATE devices SET rotation_required = 1 WHERE id = ?`, a.phone.id);
    await code();
    expect(s.relay.sent).toEqual([]);
    s.deps(a.accountId).sql.run(`UPDATE devices SET rotation_required = 0 WHERE id = ?`, a.phone.id);

    s.config.push = false;
    await code();
    expect(s.relay.sent).toEqual([]);
    s.config.push = true;
    await code();
    expect(s.relay.sent).toHaveLength(1);
  });

  it("中继答复句柄已失效时删除句柄，之后不再发", async () => {
    const { s, a } = await setup();
    s.relay.result = "gone";
    const r = await requestPairing(s, a, { code: await a.pairingCode(s) });
    await waitApproval(s, a, r.json);
    await s.flush();
    expect(s.relay.sent).toHaveLength(1);
    const row = s.deps(a.accountId).sql.all<{ push_handle: string | null }>(`SELECT push_handle FROM devices WHERE id = ?`, a.phone.id);
    expect(row[0]!.push_handle).toBeNull();
  });
});

describe("删除句柄", () => {
  it("关闭后台通知时删除；本机退出、被撤销时删除并通知中继", async () => {
    const { s, a } = await setup();
    await s.ok("DELETE", "/api/v1/devices/self/push", { token: a.phone.token });
    const sql = s.deps(a.accountId).sql;
    expect(sql.all<{ push_handle: string | null }>(`SELECT push_handle FROM devices`)[0]!.push_handle).toBeNull();

    await s.ok("PUT", "/api/v1/devices/self/push", { token: a.phone.token, body: { handle: HANDLE } });
    await s.ok("POST", "/api/v1/devices/self/revoke", { token: a.phone.token, body: { confirmLast: true } });
    await s.flush();
    expect(s.relay.removed).toEqual([HANDLE]);
    expect(sql.all<{ push_handle: string | null }>(`SELECT push_handle FROM devices`)[0]!.push_handle).toBeNull();
  });
});

describe("中继客户端", () => {
  it("not_found 归为句柄失效，其他失败和网络错误一律忽略", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    let res: () => Response = () => Response.json({});
    const client = relayClient("https://relay.example", (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return res();
    }) as typeof fetch);
    expect(await client.notify(HANDLE, "approval")).toBe("ok");
    expect(calls[0]!.url).toBe("https://relay.example/api/v1/notify");
    expect((calls[0]!.init.headers as Record<string, string>).authorization).toBe(`Bearer ${HANDLE}`);
    expect(JSON.parse(calls[0]!.init.body as string)).toEqual({ type: "approval" });
    res = () => Response.json({ error: "not_found" }, { status: 404 });
    expect(await client.notify(HANDLE, "pairing")).toBe("gone");
    res = () => Response.json({ error: "rate_limited" }, { status: 429 });
    expect(await client.notify(HANDLE, "pairing")).toBe("failed");
    res = () => {
      throw new Error("offline");
    };
    expect(await client.notify(HANDLE, "pairing")).toBe("failed");
    await client.remove(HANDLE);
    expect(calls.at(-1)!.init.method).toBe("DELETE");
  });
});
