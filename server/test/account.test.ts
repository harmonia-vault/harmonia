import { describe, expect, it } from "vitest";
import { b64 } from "../src/core/util";
import { rand, TestAccount, TestServer } from "./helpers";

describe("注册与登录", () => {
  it("验证邮箱后才能登录", async () => {
    const s = new TestServer();
    const email = "first@example.com";
    const body = { email, kdfSalt: b64(rand(16)), authKey: b64(rand(32)) };
    const reg = await s.ok("POST", "/api/v1/register", { body });
    expect(reg.verificationRequired).toBe(true);
    expect(s.mails).toHaveLength(1);
    const early = await s.call("POST", "/api/v1/auth/login", { body });
    expect(early.json.error).toBe("email_unverified");
    const wrong = await s.call("POST", "/api/v1/register/verify", { body: { email, code: "AAAAAAAA" } });
    expect(wrong.status).toBe(400);
    await s.ok("POST", "/api/v1/register/verify", { body: { email, code: s.lastCode("verification").toLowerCase() } });
    const login = await s.ok("POST", "/api/v1/auth/login", { body });
    expect(login.accountId).toBe(reg.accountId);
    const info = await s.ok("GET", "/api/v1/account", { token: login.token });
    expect(info).toMatchObject({ email, initialized: false });
  });

  it("关闭注册时只允许第一个账号，开启后可以多账号且相互隔离", async () => {
    const s = new TestServer();
    expect((await s.ok("GET", "/api/v1/instance")).registration.open).toBe(true);
    const a = await TestAccount.create(s);
    expect((await s.ok("GET", "/api/v1/instance")).registration.open).toBe(false);
    const denied = await s.call("POST", "/api/v1/register", {
      body: { email: "second@example.com", kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
    });
    expect(denied.status).toBe(403);
    s.config.allowRegistration = true;
    const b = await TestAccount.create(s);
    expect(b.accountId).not.toBe(a.accountId);
    const envA = await a.createEnv(s, [a.phone.id]);
    const syncB = await s.ok("GET", "/api/v1/sync?since=0", { token: b.phone.token });
    expect(syncB.environments).toHaveLength(0);
    // B 的令牌不能访问 A 的数据：令牌里的账号 ID 决定了路由目标。
    const cross = await s.call("PATCH", `/api/v1/environments/${envA}`, { token: b.phone.token, body: { name: "x" } });
    expect(cross.status).toBe(404);
  });

  it("重复注册已存在的邮箱会被拒绝", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    const a = await TestAccount.create(s);
    const r = await s.call("POST", "/api/v1/register", {
      body: { email: a.email, kdfSalt: b64(rand(16)), authKey: b64(rand(32)) },
    });
    expect(r.status).toBe(409);
  });

  it("不需要验证邮箱时注册后直接可用；未配置发信时需要验证会报错", async () => {
    const s = new TestServer();
    s.mailAvailable = false;
    const body = { email: "x@example.com", kdfSalt: b64(rand(16)), authKey: b64(rand(32)) };
    expect((await s.call("POST", "/api/v1/register", { body })).json.error).toBe("email_unavailable");
    s.config.requireVerification = false;
    const reg = await s.ok("POST", "/api/v1/register", { body });
    expect(reg.verificationRequired).toBe(false);
    await s.ok("POST", "/api/v1/auth/login", { body });
  });

  it("找回密码只改密码，旧密码失效", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await s.ok("POST", "/api/v1/password-reset/request", { body: { email: a.email } });
    const again = await s.call("POST", "/api/v1/password-reset/request", { body: { email: a.email } });
    expect(again.status).toBe(429);
    const newKey = b64(rand(32));
    await s.ok("POST", "/api/v1/password-reset/complete", {
      body: { email: a.email, code: s.lastCode("password"), kdfSalt: b64(rand(16)), authKey: newKey },
    });
    expect((await s.call("POST", "/api/v1/auth/login", { body: { email: a.email, authKey: a.authKey } })).status).toBe(401);
    await s.ok("POST", "/api/v1/auth/login", { body: { email: a.email, authKey: newKey } });
    // 设备不受影响。
    await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
  });

  it("重置账号删除全部数据，邮箱可以重新注册", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await a.createEnv(s, [a.phone.id]);
    await s.ok("POST", "/api/v1/account-reset/request", { body: { email: a.email } });
    await s.ok("POST", "/api/v1/account-reset/complete", { body: { email: a.email, code: s.lastCode("reset") } });
    expect(s.pushes.some((p) => p.msg.type === "revoked")).toBe(true);
    expect((await s.call("GET", "/api/v1/sync?since=0", { token: a.phone.token })).status).toBe(401);
    expect((await s.call("POST", "/api/v1/auth/login", { body: { email: a.email, authKey: a.authKey } })).status).toBe(404);
    const again = await TestAccount.create(s, a.email);
    expect(again.accountId).not.toBe(a.accountId);
  });

  it("验证码输错 5 次后失效", async () => {
    const s = new TestServer();
    const body = { email: "y@example.com", kdfSalt: b64(rand(16)), authKey: b64(rand(32)) };
    await s.ok("POST", "/api/v1/register", { body });
    for (let i = 0; i < 5; i++) {
      await s.call("POST", "/api/v1/register/verify", { body: { email: body.email, code: "BBBBBBBB" } });
    }
    const r = await s.call("POST", "/api/v1/register/verify", { body: { email: body.email, code: s.lastCode("verification") } });
    expect(r.json.message).toContain("失效");
  });
});
