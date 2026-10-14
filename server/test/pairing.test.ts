import { describe, expect, it } from "vitest";
import { checkWaiters, MAX_ANONYMOUS, MAX_AUTHORIZED, pairingLeft, WAITER_TIMEOUT } from "../src/core/pairing";
import { MAX_PAIRING_CODES } from "../src/core/pairing-codes";
import { b64 } from "../src/core/util";
import { pairClient, rand, requestPairing, TestAccount, TestServer, waitApproval } from "./helpers";

const IP = "203.0.113.7";

/** 电脑发起一个匿名配对请求（尚未连上等待连接）。 */
const request = (s: TestServer, a: TestAccount, ip = IP, canManage = false) => requestPairing(s, a, { ip, canManage });

const pending = async (s: TestServer, a: TestAccount) =>
  (await s.ok("GET", "/api/v1/pairings", { token: a.phone.token })).pairings.map((p: { id: string; authorized: boolean }) => [
    p.id,
    p.authorized,
  ]);

const status = async (s: TestServer, a: TestAccount, req: Record<string, any>) =>
  (
    await s.ok("GET", `/api/v1/pairings/${req.id}/status`, {
      headers: { "x-harmonia-account": a.accountId, "x-pairing-secret": req.secret },
    })
  ).status;

const pairingPushes = (s: TestServer, a: TestAccount) =>
  s.pushes.filter((p) => p.account === a.accountId && p.msg.type === "pairing").length;

describe("匿名配对请求", () => {
  it("不需要会话；不推送给管理设备，但扫码（按 ID）和列表中都能取到，并带上来源 IP", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const r = await request(s, a);
    expect([r.status, r.json.authorized]).toEqual([200, false]);
    expect(r.json.expiresAt - s.clock).toBe(5 * 60_000);
    const req = r.json;
    expect(await pending(s, a)).toEqual([]);
    const approve = await s.call("POST", `/api/v1/pairings/${req.id}/approve`, { token: a.phone.token, body: {} });
    expect(approve.status).toBe(409);

    expect((await waitApproval(s, a, req)).status).toBe(200);
    expect(pairingPushes(s, a)).toBe(0);
    const list = await s.ok("GET", "/api/v1/pairings", { token: a.phone.token });
    expect(list.pairings.map((p: { id: string; ip: string; authorized: boolean }) => [p.id, p.ip, p.authorized])).toEqual([
      [req.id, IP, false],
    ]);
    expect((await s.ok("GET", `/api/v1/pairings/${req.id}`, { token: a.phone.token })).id).toBe(req.id);
    // 同一请求只能有一条等待连接。
    expect((await waitApproval(s, a, req)).status).toBe(409);

    // 发起方离开、过期都不推送。
    s.waiters(a.accountId).open.delete(req.id);
    pairingLeft(s.deps(a.accountId), req.id);
    expect(await status(s, a, req)).toBe("cancelled");
    expect(pairingPushes(s, a)).toBe(0);
  });

  it("只能发给已初始化的账号；账号公钥不一致、缺少字段时拒绝", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const missing = await s.call("POST", "/api/v1/pairings", {
      headers: { "x-harmonia-account": a.accountId },
      body: { name: "x", platform: "linux", signPub: b64(rand(32)), boxPub: b64(rand(32)), rootPub: a.root.pub },
    });
    expect(missing.status).toBe(400);
    const wrongRoot = await s.call("POST", "/api/v1/pairings", {
      headers: { "x-harmonia-account": a.accountId },
      body: { name: "x", platform: "linux", signPub: b64(rand(32)), boxPub: b64(rand(32)), rootPub: b64(rand(32)), canManage: false },
    });
    expect(wrongRoot.status).toBe(409);
    const noAccount = await s.call("POST", "/api/v1/pairings", { body: {} });
    expect(noAccount.status).toBe(401);
  });
});

describe("配对码", () => {
  it("只有管理设备能生成；带配对码的请求推送给管理设备，配对码用一次即作废", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const code = await a.pairingCode(s);
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    // 解析规则同协议 2.1：小写、分组、O 当作 0 都可以。
    const typed = `${code.slice(0, 4)}-${code.slice(4)}`.toLowerCase().replace(/0/g, "o");
    const r = await requestPairing(s, a, { ip: IP, code: typed });
    expect([r.status, r.json.authorized]).toEqual([200, true]);
    expect(pairingPushes(s, a)).toBe(0);
    await waitApproval(s, a, r.json);
    expect(pairingPushes(s, a)).toBe(1);
    expect(await pending(s, a)).toEqual([[r.json.id, true]]);

    const reused = await requestPairing(s, a, { ip: "198.51.100.1", code });
    expect([reused.status, reused.json.error]).toEqual([401, "unauthorized"]);
    expect(reused.json.message).toContain("重新生成");

    // 发起方离开时通知管理设备刷新。
    s.waiters(a.accountId).open.delete(r.json.id);
    pairingLeft(s.deps(a.accountId), r.json.id);
    expect(pairingPushes(s, a)).toBe(2);
  });

  it("多个配对码同时有效，各自用掉或过期才失效；默认 10 分钟", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const first = await a.pairingCode(s);
    const second = await a.pairingCode(s);
    expect((await requestPairing(s, a, { ip: IP, code: first })).status).toBe(200);
    expect((await requestPairing(s, a, { ip: "198.51.100.1", code: second })).status).toBe(200);
    const third = await a.pairingCode(s);
    s.clock += 10 * 60_000;
    expect((await requestPairing(s, a, { ip: "192.0.2.1", code: third })).status).toBe(401);
  });

  it("有效期可选 5 到 60 分钟，超出范围拒绝", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const long = await a.pairingCode(s, 60);
    const short = await a.pairingCode(s, 5);
    s.clock += 5 * 60_000;
    expect((await requestPairing(s, a, { ip: IP, code: short })).status).toBe(401);
    s.clock += 55 * 60_000 - 1;
    expect((await requestPairing(s, a, { ip: "198.51.100.1", code: long })).status).toBe(200);
    for (const minutes of [4, 61, 7.5, "10"]) {
      const r = await s.call("POST", "/api/v1/pairing-codes", { token: a.phone.token, body: { minutes } });
      expect([r.status, r.json.error]).toEqual([400, "invalid_request"]);
    }
  });

  it(`同时最多 ${MAX_PAIRING_CODES} 个，超出时作废最早生成的那个`, async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const codes: string[] = [];
    for (let i = 0; i <= MAX_PAIRING_CODES; i++) codes.push(await a.pairingCode(s));
    expect((await requestPairing(s, a, { ip: IP, code: codes[0] })).status).toBe(401);
    expect((await requestPairing(s, a, { ip: "198.51.100.1", code: codes[1] })).status).toBe(200);
    expect((await requestPairing(s, a, { ip: "192.0.2.1", code: codes.at(-1) })).status).toBe(200);
  });

  it("电脑和没有会话的请求不能生成配对码", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const cli = await pairClient(s, a, []);
    const r = await s.call("POST", "/api/v1/pairing-codes", { token: cli.token, body: {} });
    expect(r.status).toBe(403);
    expect((await s.call("POST", "/api/v1/pairing-codes", { body: {} })).status).toBe(401);
  });

  it("输错按网络递增等待，成功后清零；其他网络不受影响", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const code = await a.pairingCode(s);
    const bad = "203.0.113.1";
    for (let i = 0; i < 5; i++) expect((await requestPairing(s, a, { ip: bad, code: "ZZZZZZZZ" })).status).toBe(401);
    // 等待期内不校验，即使配对码是对的。
    const blocked = await requestPairing(s, a, { ip: bad, code });
    expect([blocked.status, blocked.json.error, blocked.json.retryAfter]).toEqual([429, "rate_limited", 5]);
    expect(blocked.json.message).toContain("扫码");
    // 格式不对同样算输错。
    s.clock += 5_000;
    expect((await requestPairing(s, a, { ip: bad, code: "12" })).status).toBe(401);
    expect((await requestPairing(s, a, { ip: bad, code })).json.retryAfter).toBe(10);
    // 不带配对码的匿名请求不受影响。
    expect((await requestPairing(s, a, { ip: bad })).status).toBe(200);
    // 另一个网络用正确的配对码可以发起；配对码不因别人输错而作废。
    expect((await requestPairing(s, a, { ip: "198.51.100.7", code })).status).toBe(200);

    s.clock += 10_000;
    const code2 = await a.pairingCode(s);
    expect((await requestPairing(s, a, { ip: bad, code: code2 })).status).toBe(200);
    // 成功后清零：又有 5 次免等待的机会（先等过每分钟的发起次数限制）。
    s.clock += 60_000;
    for (let i = 0; i < 5; i++) expect((await requestPairing(s, a, { ip: bad, code: "ZZZZZZZZ" })).status).toBe(401);
  });

  it("匿名请求占满额度时，用配对码仍然可以发起；配对码请求另有较小的上限", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    for (let i = 0; i < MAX_ANONYMOUS; i++) expect((await request(s, a, `192.0.2.${i + 1}`)).status).toBe(200);
    const full = await request(s, a, "198.51.100.50");
    expect([full.status, full.json.error]).toEqual([429, "rate_limited"]);
    expect(full.json.message).toContain("生成配对码");

    const ids: string[] = [];
    for (let i = 0; i < MAX_AUTHORIZED; i++) {
      const code = await a.pairingCode(s);
      const r = await requestPairing(s, a, { ip: `198.51.100.${60 + i}`, code });
      expect(r.status).toBe(200);
      ids.push(r.json.id);
    }
    const code = await a.pairingCode(s);
    expect((await requestPairing(s, a, { ip: "198.51.100.70", code })).status).toBe(429);
    // 超出上限时配对码没有被用掉：处理掉一个请求后，同一个配对码可以发起。
    await s.ok("POST", `/api/v1/pairings/${ids[0]}/reject`, { token: a.phone.token, body: {} });
    expect((await requestPairing(s, a, { ip: "198.51.100.70", code })).status).toBe(200);
  });
});

describe("配对等待连接", () => {
  it("心跳超时的请求作废；过期的请求通知发起方", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const quiet = (await request(s, a)).json;
    const alive = (await request(s, a, "198.51.100.1")).json;
    await waitApproval(s, a, quiet);
    await waitApproval(s, a, alive);
    const w = s.waiters(a.accountId);
    s.clock += WAITER_TIMEOUT + 1;
    w.ping(alive.id);
    expect(checkWaiters(s.deps(a.accountId))).toBe(true);
    expect(w.results.get(quiet.id)).toBe("left");
    expect(await status(s, a, quiet)).toBe("cancelled");
    expect(await pending(s, a)).toEqual([[alive.id, false]]);

    s.clock += 5 * 60_000;
    w.ping(alive.id);
    expect(checkWaiters(s.deps(a.accountId))).toBe(false);
    expect(w.results.get(alive.id)).toBe("expired");
  });

  it("拒绝时可以阻止该 IP 30 分钟，发起方收到拒绝结果", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const req = (await request(s, a)).json;
    await waitApproval(s, a, req);
    await s.ok("POST", `/api/v1/pairings/${req.id}/reject`, { token: a.phone.token, body: { block: true } });
    expect(s.waiters(a.accountId).results.get(req.id)).toBe("rejected");
    expect(await status(s, a, req)).toBe("rejected");

    const blocked = await request(s, a);
    expect([blocked.status, blocked.json.error]).toEqual([429, "pairing_blocked"]);
    expect((await request(s, a, "198.51.100.1")).status).toBe(200);
    s.clock += 30 * 60_000;
    expect((await request(s, a)).status).toBe(200);
  });

  it("只有声明具备管理功能的客户端才能被批准为管理设备", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const cli = (await request(s, a)).json;
    const phone = (await request(s, a, "198.51.100.1", true)).json;
    await waitApproval(s, a, cli);
    await waitApproval(s, a, phone);
    const list = await s.ok("GET", "/api/v1/pairings", { token: a.phone.token });
    const flags = Object.fromEntries(list.pairings.map((p: { id: string; canManage: boolean }) => [p.id, p.canManage]));
    expect(flags).toEqual({ [cli.id]: false, [phone.id]: true });
    const r = await s.call("POST", `/api/v1/pairings/${cli.id}/approve`, {
      token: a.phone.token,
      body: { kind: "manager", cert: b64(rand(64)), rootSealed: b64(rand(80)), envelopes: [] },
    });
    expect([r.status, r.json.error]).toEqual([400, "invalid_request"]);
  });
});
