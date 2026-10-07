import { describe, expect, it } from "vitest";
import { network } from "../src/core/net";
import { b64 } from "../src/core/util";
import { FakeDevice, rand, TestAccount, TestServer, waitApproval } from "./helpers";

const login = (s: TestServer, a: TestAccount, ip: string, authKey = a.authKey, extra: Record<string, string> = {}) =>
  s.call("POST", "/api/v1/auth/login", { body: { email: a.email, authKey, ...extra }, ip });

/** 从 count 个不同网络各输错一次，让账号进入受攻击状态。 */
async function attack(s: TestServer, a: TestAccount, count = 20) {
  for (let i = 0; i < count; i++) await login(s, a, `192.0.2.${i + 1}`, b64(rand(32)));
}

describe("网络", () => {
  it("IPv4 按单个地址，IPv6 按 /64，放宽时按 /48", () => {
    expect(network("203.0.113.9")).toBe("203.0.113.9");
    expect(network("2001:db8:1:2:3:4:5:6")).toBe("2001:db8:1:2");
    expect(network("2001:0db8:0001:0002::1")).toBe("2001:db8:1:2");
    expect(network("2001:db8::1")).toBe("2001:db8:0:0");
    expect(network("2001:db8:1:2::9", true)).toBe("2001:db8:1");
  });
});

describe("密码登录", () => {
  it("同一网络输错 5 次后需要等待，等待时间翻倍；其他网络不受影响", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const bad = "203.0.113.1";
    for (let i = 0; i < 5; i++) expect((await login(s, a, bad, b64(rand(32)))).status).toBe(401);
    const blocked = await login(s, a, bad);
    expect([blocked.status, blocked.json.error, blocked.json.retryAfter]).toEqual([429, "rate_limited", 5]);
    expect((await login(s, a, "198.51.100.7")).status).toBe(200);

    s.clock += 5_000;
    expect((await login(s, a, bad, b64(rand(32)))).status).toBe(401);
    expect((await login(s, a, bad)).json.retryAfter).toBe(10);
    s.clock += 10_000;
    expect((await login(s, a, bad)).status).toBe(200);
  });

  it("受攻击且配置了发信时，密码正确后还要邮件验证码；密码不对时不发邮件", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const mails = s.mails.length;
    await attack(s, a);
    expect(s.mails.length).toBe(mails);

    const ip = "198.51.100.20";
    const first = await login(s, a, ip);
    expect([first.status, first.json.error]).toEqual([401, "code_required"]);
    expect(first.json.message).toContain("u***@example.com");
    const wrong = await login(s, a, ip, a.authKey, { flow: first.json.flow, code: "ZZZZZZZZ" });
    expect(wrong.status).toBe(400);
    const ok = await login(s, a, ip, a.authKey, { flow: first.json.flow, code: s.lastCode("login") });
    expect(ok.status).toBe(200);
  });

  it("受攻击且没有配置发信时，每个网络只有 1 次免限制机会，输对密码仍可登录", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    s.mailAvailable = false;
    await attack(s, a);
    expect((await login(s, a, "198.51.100.30")).status).toBe(200);
    expect((await login(s, a, "198.51.100.31", b64(rand(32)))).status).toBe(401);
    expect((await login(s, a, "198.51.100.31")).status).toBe(429);
  });

  it("修改密码后退出受攻击状态", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await attack(s, a);
    a.authKey = b64(rand(32));
    await s.ok("PUT", "/api/v1/account/password", { token: a.phone.token, body: { kdfSalt: b64(rand(16)), authKey: a.authKey } });
    expect((await login(s, a, "198.51.100.40")).status).toBe(200);
  });

  it("连续 1 小时没有失败后退出受攻击状态", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await attack(s, a);
    s.clock += 60 * 60_000 + 1;
    expect((await login(s, a, "198.51.100.50")).status).toBe(200);
  });
});

describe("邮件验证码与发信额度", () => {
  it("别人输错自己的验证码，不影响你收到的验证码", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const mine = await s.ok("POST", "/api/v1/password-reset/request", { body: { email: a.email }, ip: "203.0.113.60" });
    const myCode = s.lastCode("password");
    const theirs = await s.ok("POST", "/api/v1/password-reset/request", { body: { email: a.email }, ip: "198.51.100.60" });
    for (let i = 0; i < 5; i++) {
      await s.call("POST", "/api/v1/password-reset/complete", {
        body: { email: a.email, flow: theirs.flow, code: "ZZZZZZZZ", kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
      });
    }
    await s.ok("POST", "/api/v1/password-reset/complete", {
      body: { email: a.email, flow: mine.flow, code: myCode, kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
    });
  });

  it("其他用途：每个网络每小时 2 封，合计每小时 6 封；超出后已发出的验证码仍有效", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const reset = (ip: string) => s.call("POST", "/api/v1/password-reset/request", { body: { email: a.email }, ip });
    expect((await reset("203.0.113.70")).status).toBe(200);
    s.clock += 61_000;
    expect((await reset("203.0.113.70")).status).toBe(200);
    s.clock += 61_000;
    expect((await reset("203.0.113.70")).status).toBe(429);

    // 注册验证邮件也计入同一份额度：这里已经发过 1 封，再从 3 个网络各发 1 封到 6 封。
    const flows = [];
    for (let i = 0; i < 3; i++) flows.push((await reset(`198.51.100.${70 + i}`)).json.flow);
    const over = await reset("198.51.100.80");
    expect(over.status).toBe(429);
    await s.ok("POST", "/api/v1/password-reset/complete", {
      body: { email: a.email, flow: flows[2], code: s.lastCode("password"), kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
    });
  });

  it("注册验证邮件按网络限制：每小时 3 封", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    const ip = "203.0.113.90";
    for (let i = 0; i < 3; i++) {
      const body = { email: `r${i}@example.com`, kdfSalt: b64(rand(16)), authKey: b64(rand(32)) };
      expect((await s.call("POST", "/api/v1/register", { body, ip })).status).toBe(200);
    }
    const body = { email: "r9@example.com", kdfSalt: b64(rand(16)), authKey: b64(rand(32)) };
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

  it("每个网络同时最多 2 个等待批准的配对请求", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const request = async (ip: string) => {
      const d = await FakeDevice.create();
      const pw = await a.passwordLogin(s);
      return s.call("POST", "/api/v1/pairings", {
        token: pw.token,
        ip,
        body: { name: "x", platform: "linux", signPub: d.sign.pub, boxPub: d.boxPub, rootPub: a.root.pub, canManage: false },
      });
    };
    for (let i = 0; i < 2; i++) await waitApproval(s, a, (await request("2001:db8:5:6::1")).json);
    expect((await request("2001:db8:5:6::2")).status).toBe(429);
    expect((await request("2001:db8:5:7::1")).status).toBe(200);
  });
});
