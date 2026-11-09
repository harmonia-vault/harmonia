import { describe, expect, it } from "vitest";
import { TestAccount, TestServer } from "./helpers";

const IP = "198.51.100.7";

/** 同一网络连续请求设备登录挑战，返回最后一次的状态码。 */
async function challenges(s: TestServer, a: TestAccount, times: number) {
  let status = 0;
  for (let i = 0; i < times; i++) {
    const r = await s.call("POST", "/api/v1/auth/challenge", {
      body: { deviceId: a.phone.id },
      headers: { "x-harmonia-account": a.accountId },
      ip: IP,
    });
    status = r.status;
  }
  return status;
}

describe("按网络的每分钟限流", () => {
  it("同一网络每分钟最多 30 次设备登录挑战，下一分钟恢复", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s, "limit@example.com");
    expect(await challenges(s, a, 30)).toBe(200);
    expect(await challenges(s, a, 1)).toBe(429);
    s.clock += 61_000;
    expect(await challenges(s, a, 1)).toBe(200);
  });

  it("以邮箱为入口的接口按网络限制每分钟次数", async () => {
    const s = new TestServer();
    let last = 0;
    for (let i = 0; i < 21; i++) {
      last = (await s.call("GET", "/api/v1/accounts/lookup?email=nobody@example.com", { ip: IP })).status;
    }
    expect(last).toBe(429);
  });

  it("同一网络 60 秒内只能重发一次验证码", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    await s.ok("POST", "/api/v1/register", { body: { email: "a@example.com" }, ip: IP });
    const again = await s.call("POST", "/api/v1/register", { body: { email: "a@example.com" }, ip: IP });
    expect([again.status, again.json.error]).toEqual([429, "rate_limited"]);
  });

  it("本地测试放宽后：不受每分钟次数和重发间隔限制，邮件额度照常", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    const a = await TestAccount.create(s, "relaxed@example.com");
    s.config.relaxedLimits = true;
    expect(await challenges(s, a, 40)).toBe(200);
    for (let i = 0; i < 25; i++) {
      expect((await s.call("GET", "/api/v1/accounts/lookup?email=nobody@example.com", { ip: IP })).status).toBe(404);
    }
    // 注册验证邮件每个网络每小时 3 封，放宽后仍然有效。
    for (const email of ["b@example.com", "c@example.com", "d@example.com"]) {
      await s.ok("POST", "/api/v1/register", { body: { email }, ip: IP });
    }
    const over = await s.call("POST", "/api/v1/register", { body: { email: "e@example.com" }, ip: IP });
    expect([over.status, over.json.error]).toEqual([429, "rate_limited"]);
  });
});
