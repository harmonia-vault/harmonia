import { describe, expect, it } from "vitest";
import { network } from "../src/core/net";
import { requestPairing, TestAccount, TestServer, waitApproval } from "./helpers";

describe("网络", () => {
  it("IPv4 按单个地址，IPv6 按 /64", () => {
    expect(network("203.0.113.9")).toBe("203.0.113.9");
    expect(network("2001:db8:1:2:3:4:5:6")).toBe("2001:db8:1:2");
    expect(network("2001:0db8:0001:0002::1")).toBe("2001:db8:1:2");
    expect(network("2001:db8::1")).toBe("2001:db8:0:0");
  });
});

describe("邮件验证码与发信额度", () => {
  it("别人输错自己的验证码，不影响你收到的验证码", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const mine = await s.ok("POST", "/api/v1/account-reset/request", { body: { email: a.email }, ip: "203.0.113.60" });
    const myCode = s.lastCode("reset");
    const theirs = await s.ok("POST", "/api/v1/account-reset/request", { body: { email: a.email }, ip: "198.51.100.60" });
    for (let i = 0; i < 5; i++) {
      await s.call("POST", "/api/v1/account-reset/complete", { body: { email: a.email, flow: theirs.flow, code: "ZZZZZZZZ" } });
    }
    await s.ok("POST", "/api/v1/account-reset/complete", { body: { email: a.email, flow: mine.flow, code: myCode } });
  });

  it("每个网络每小时 2 封，合计每小时 6 封；超出后已发出的验证码仍有效", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const reset = (ip: string) => s.call("POST", "/api/v1/account-reset/request", { body: { email: a.email }, ip });
    expect((await reset("203.0.113.70")).status).toBe(200);
    const again = await reset("203.0.113.70");
    expect([again.status, again.json.retryAfter > 0]).toEqual([429, true]);
    s.clock += 61_000;
    expect((await reset("203.0.113.70")).status).toBe(200);
    s.clock += 61_000;
    expect((await reset("203.0.113.70")).status).toBe(429);

    // 注册验证邮件也计入同一份额度：这里已经发过 1 封，再从 3 个网络各发 1 封到 6 封。
    const flows = [];
    for (let i = 0; i < 3; i++) flows.push((await reset(`198.51.100.${70 + i}`)).json.flow);
    const over = await reset("198.51.100.80");
    expect(over.status).toBe(429);
    expect(over.json.message).toContain("15 分钟内仍然有效");
    await s.ok("POST", "/api/v1/account-reset/complete", { body: { email: a.email, flow: flows[2], code: s.lastCode("reset") } });
  });

  it("注册验证邮件按网络限制：每小时 3 封", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    const ip = "203.0.113.90";
    for (let i = 0; i < 3; i++) {
      expect((await s.call("POST", "/api/v1/register", { body: { email: `r${i}@example.com` }, ip })).status).toBe(200);
    }
    const body = { email: "r9@example.com" };
    expect((await s.call("POST", "/api/v1/register", { body, ip })).status).toBe(429);
    expect((await s.call("POST", "/api/v1/register", { body, ip: "198.51.100.90" })).status).toBe(200);
  });
});

describe("入口与配对", () => {
  it("入口总量超限时直接拒绝", async () => {
    const s = new TestServer();
    s.entryLimit = async () => false;
    const r = await s.call("GET", "/api/v1/instance");
    expect([r.status, r.json.retryAfter]).toEqual([429, 60]);
  });

  it("匿名查询账号按网络限制每分钟次数", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const lookup = () => s.call("GET", `/api/v1/accounts/lookup?email=${a.email}`, { ip: "203.0.113.30" });
    for (let i = 0; i < 20; i++) expect((await lookup()).status).toBe(200);
    expect((await lookup()).status).toBe(429);
    expect((await s.call("GET", `/api/v1/accounts/lookup?email=${a.email}`, { ip: "198.51.100.30" })).status).toBe(200);
  });

  it("每个网络同时最多 2 个等待批准的配对请求，匿名和配对码创建的都算", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await waitApproval(s, a, (await requestPairing(s, a, { ip: "2001:db8:5:6::1" })).json);
    const code = await a.pairingCode(s);
    await waitApproval(s, a, (await requestPairing(s, a, { ip: "2001:db8:5:6::3", code })).json);
    expect((await requestPairing(s, a, { ip: "2001:db8:5:6::2" })).status).toBe(429);
    expect((await requestPairing(s, a, { ip: "2001:db8:5:7::1" })).status).toBe(200);
  });
});
