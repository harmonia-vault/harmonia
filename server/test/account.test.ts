import { describe, expect, it } from "vitest";
import { register, TestAccount, TestServer } from "./helpers";

describe("注册与查询账号", () => {
  it("验证邮箱后才发放注册会话，注册会话只能查看账号信息和初始化", async () => {
    const s = new TestServer();
    const email = "first@example.com";
    const reg = await s.ok("POST", "/api/v1/register", { body: { email } });
    expect(reg.verificationRequired).toBe(true);
    expect(reg.token).toBeUndefined();
    expect(s.mails).toHaveLength(1);
    const wrong = await s.call("POST", "/api/v1/register/verify", { body: { email, flow: reg.flow, code: "AAAAAAAA" } });
    expect(wrong.status).toBe(400);
    const noFlow = await s.call("POST", "/api/v1/register/verify", { body: { email, code: s.lastCode("verification") } });
    expect(noFlow.status).toBe(400);
    const v = await s.ok("POST", "/api/v1/register/verify", {
      body: { email, flow: reg.flow, code: s.lastCode("verification").toLowerCase() },
    });
    expect(v.accountId).toBe(reg.accountId);
    // 同一个验证码不能再换一次会话。
    const replay = await s.call("POST", "/api/v1/register/verify", { body: { email, flow: reg.flow, code: s.lastCode("verification") } });
    expect(replay.status).toBe(400);
    const info = await s.ok("GET", "/api/v1/account", { token: v.token });
    expect(info).toMatchObject({ email, initialized: false });
    const sync = await s.call("GET", "/api/v1/sync?since=0", { token: v.token });
    expect(sync.status).toBe(401);
  });

  it("匿名查询：未注册返回 not_found，未初始化不带 rootPub，初始化后带 rootPub", async () => {
    const s = new TestServer();
    s.config.allowRegistration = true;
    const lookup = (email: string) => s.call("GET", `/api/v1/accounts/lookup?email=${encodeURIComponent(email)}`);
    expect((await lookup("nobody@example.com")).json.error).toBe("not_found");

    const reg = await register(s, "half@example.com");
    expect((await lookup("HALF@example.com")).json).toEqual({ accountId: reg.accountId, initialized: false });

    const a = await TestAccount.create(s);
    expect((await lookup(a.email)).json).toEqual({ accountId: a.accountId, initialized: true, rootPub: a.root.pub });
  });

  it("已注册但未初始化的账号可以重新注册，原来的注册会话作废；初始化后不能再注册", async () => {
    const s = new TestServer();
    const email = "again@example.com";
    const first = await register(s, email);
    const second = await register(s, email);
    expect(second.accountId).toBe(first.accountId);
    expect((await s.call("GET", "/api/v1/account", { token: first.token })).status).toBe(401);
    await s.ok("GET", "/api/v1/account", { token: second.token });

    const a = await TestAccount.create(s, "done@example.com").catch(() => null);
    // 关闭注册时，第二个邮箱不能注册；同一邮箱可以继续完成初始化。
    expect(a).toBeNull();
    const done = await TestAccount.create(s, email);
    const again = await s.call("POST", "/api/v1/register", { body: { email } });
    expect([again.status, again.json.error]).toEqual([409, "conflict"]);
    expect(done.accountId).toBe(first.accountId);
  });

  it("关闭注册时只允许第一个账号，开启后可以多账号且相互隔离", async () => {
    const s = new TestServer();
    expect((await s.ok("GET", "/api/v1/instance")).registration).toMatchObject({ open: true, first: true });
    const a = await TestAccount.create(s);
    expect((await s.ok("GET", "/api/v1/instance")).registration).toMatchObject({ open: false, first: false });
    const denied = await s.call("POST", "/api/v1/register", { body: { email: "second@example.com" } });
    expect(denied.status).toBe(403);
    s.config.allowRegistration = true;
    // 开放注册后可以注册，但已经有账号，客户端提示的是普通注册。
    expect((await s.ok("GET", "/api/v1/instance")).registration).toMatchObject({ open: true, first: false });
    const b = await TestAccount.create(s);
    expect(b.accountId).not.toBe(a.accountId);
    const envA = await a.createEnv(s, [a.phone.id]);
    const syncB = await s.ok("GET", "/api/v1/sync?since=0", { token: b.phone.token });
    expect(syncB.environments).toHaveLength(0);
    // B 的令牌不能访问 A 的数据：令牌里的账号 ID 决定了路由目标。
    const cross = await s.call("PATCH", `/api/v1/environments/${envA}`, { token: b.phone.token, body: { name: "x" } });
    expect(cross.status).toBe(404);
  });

  it("不需要验证邮箱时注册直接发放会话；未配置发信时需要验证会报错", async () => {
    const s = new TestServer();
    s.mailAvailable = false;
    const body = { email: "x@example.com" };
    expect((await s.call("POST", "/api/v1/register", { body })).json.error).toBe("email_unavailable");
    s.config.requireVerification = false;
    const reg = await s.ok("POST", "/api/v1/register", { body });
    expect(reg.verificationRequired).toBe(false);
    expect((await s.ok("GET", "/api/v1/account", { token: reg.token })).initialized).toBe(false);
  });

  it("已删除的密码接口不再存在", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const headers = { "x-harmonia-account": a.accountId };
    expect((await s.call("GET", `/api/v1/auth/prelogin?email=${a.email}`, { headers })).status).toBe(404);
    expect((await s.call("POST", "/api/v1/auth/login", { headers, body: { email: a.email } })).status).toBe(404);
    expect((await s.call("POST", "/api/v1/password-reset/request", { headers, body: { email: a.email } })).status).toBe(404);
    expect((await s.call("PUT", "/api/v1/account/password", { token: a.phone.token, body: {} })).status).toBe(404);
  });

  it("重置账号删除全部数据，邮箱可以重新注册", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    await a.createEnv(s, [a.phone.id]);
    const { flow } = await s.ok("POST", "/api/v1/account-reset/request", { body: { email: a.email } });
    await s.ok("POST", "/api/v1/account-reset/complete", { body: { email: a.email, flow, code: s.lastCode("reset") } });
    expect(s.pushes.some((p) => p.msg.type === "revoked")).toBe(true);
    expect((await s.call("GET", "/api/v1/sync?since=0", { token: a.phone.token })).status).toBe(401);
    expect((await s.call("GET", `/api/v1/accounts/lookup?email=${a.email}`)).status).toBe(404);
    const again = await TestAccount.create(s, a.email);
    expect(again.accountId).not.toBe(a.accountId);
  });

  it("验证码输错 5 次后失效", async () => {
    const s = new TestServer();
    const email = "y@example.com";
    const { flow } = await s.ok("POST", "/api/v1/register", { body: { email } });
    for (let i = 0; i < 5; i++) {
      await s.call("POST", "/api/v1/register/verify", { body: { email, flow, code: "BBBBBBBB" } });
    }
    const r = await s.call("POST", "/api/v1/register/verify", { body: { email, flow, code: s.lastCode("verification") } });
    expect(r.json.message).toContain("失效");
  });
});
