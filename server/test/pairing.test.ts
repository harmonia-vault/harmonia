import { describe, expect, it } from "vitest";
import { checkWaiters, pairingLeft, WAITER_TIMEOUT } from "../src/core/pairing";
import { b64 } from "../src/core/util";
import { FakeDevice, rand, TestAccount, TestServer, waitApproval } from "./helpers";

/** 电脑发起一个配对请求（尚未连上等待连接）。 */
async function request(s: TestServer, a: TestAccount, ip = "203.0.113.7") {
  const cli = await FakeDevice.create();
  const pw = await a.passwordLogin(s);
  return s.call("POST", "/api/v1/pairings", {
    token: pw.token,
    headers: { "cf-connecting-ip": ip },
    body: { name: "笔记本", platform: "linux", signPub: cli.sign.pub, boxPub: cli.boxPub, rootPub: a.root.pub },
  });
}

const pendingIds = async (s: TestServer, a: TestAccount) =>
  (await s.ok("GET", "/api/v1/pairings", { token: a.phone.token })).pairings.map((p: { id: string }) => p.id);

const status = async (s: TestServer, a: TestAccount, req: Record<string, any>) =>
  (
    await s.ok("GET", `/api/v1/pairings/${req.id}/status`, {
      headers: { "x-harmonia-account": a.accountId, "x-pairing-secret": req.secret },
    })
  ).status;

const pairingPushes = (s: TestServer, a: TestAccount) =>
  s.pushes.filter((p) => p.account === a.accountId && p.msg.type === "pairing").length;

describe("配对等待连接", () => {
  it("连上等待连接后才通知管理手机、出现在列表中，并带上来源 IP", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const req = (await request(s, a)).json;
    expect(await pendingIds(s, a)).toEqual([]);
    expect(pairingPushes(s, a)).toBe(0);
    const approve = await s.call("POST", `/api/v1/pairings/${req.id}/approve`, { token: a.phone.token, body: {} });
    expect(approve.status).toBe(409);

    expect((await waitApproval(s, a, req)).status).toBe(200);
    expect(pairingPushes(s, a)).toBe(1);
    const list = await s.ok("GET", "/api/v1/pairings", { token: a.phone.token });
    expect(list.pairings.map((p: { id: string; ip: string }) => [p.id, p.ip])).toEqual([[req.id, "203.0.113.7"]]);
    // 同一请求只能有一条等待连接。
    expect((await waitApproval(s, a, req)).status).toBe(409);
  });

  it("发起方断开后请求作废，管理手机收到通知", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const req = (await request(s, a)).json;
    await waitApproval(s, a, req);
    s.waiters(a.accountId).open.delete(req.id);
    pairingLeft(s.deps(a.accountId), req.id);
    expect(await status(s, a, req)).toBe("cancelled");
    expect(await pendingIds(s, a)).toEqual([]);
    expect(pairingPushes(s, a)).toBe(2);
    expect((await s.call("GET", `/api/v1/pairings/${req.id}`, { token: a.phone.token })).status).toBe(409);
  });

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
    expect(await pendingIds(s, a)).toEqual([alive.id]);

    s.clock += 10 * 60_000;
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

  it("修改密码后待处理的请求全部作废", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const req = (await request(s, a)).json;
    await waitApproval(s, a, req);
    await s.ok("PUT", "/api/v1/account/password", {
      token: a.phone.token,
      body: { kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
    });
    expect(s.waiters(a.accountId).results.get(req.id)).toBe("rejected");
    expect(await status(s, a, req)).toBe("rejected");
    expect(await pendingIds(s, a)).toEqual([]);
  });
});
