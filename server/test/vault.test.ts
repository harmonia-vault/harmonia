import { describe, expect, it } from "vitest";
import { b64, recoveryAuthMsg, rootRecoveryMsg } from "../src/core/util";
import { Ed, FakeDevice, newId, pairClient, rand, TestAccount, TestServer, waitApproval } from "./helpers";

const value = () => b64(rand(60));
const put = (s: TestServer, token: string, env: string, name: string, key = newId()) =>
  s.call("PUT", `/api/v1/environments/${env}/variables/${name}`, {
    token,
    body: { value: value(), keyVersion: "1" },
    headers: { "idempotency-key": key },
  });

describe("环境、变量与同步", () => {
  it("环境封装必须覆盖全部管理设备和恢复码", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const id = newId();
    const bad = await s.call("POST", "/api/v1/environments", {
      token: a.phone.token,
      body: { id, name: "x", envelopes: [await a.envelope(id, a.phone.id)] },
    });
    expect(bad.status).toBe(400);
    const forged = await a.envelope(id, "recovery");
    forged.sig = b64(rand(64));
    const bad2 = await s.call("POST", "/api/v1/environments", {
      token: a.phone.token,
      body: { id, name: "x", envelopes: [await a.envelope(id, a.phone.id), forged] },
    });
    expect(bad2.json.message).toContain("签名");
    await a.createEnv(s, [a.phone.id]);
  });

  it("增量同步、幂等重放与删除墓碑", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const env = await a.createEnv(s, [a.phone.id]);
    const key = newId();
    const body = { value: value(), keyVersion: "1" };
    const first = await s.ok("PUT", `/api/v1/environments/${env}/variables/OPENAI_API_KEY`, {
      token: a.phone.token,
      body,
      headers: { "idempotency-key": key },
    });
    const replay = await s.ok("PUT", `/api/v1/environments/${env}/variables/OPENAI_API_KEY`, {
      token: a.phone.token,
      body,
      headers: { "idempotency-key": key },
    });
    expect(replay.seq).toBe(first.seq);
    const clash = await s.call("PUT", `/api/v1/environments/${env}/variables/OPENAI_API_KEY`, {
      token: a.phone.token,
      body: { value: value(), keyVersion: "1" },
      headers: { "idempotency-key": key },
    });
    expect(clash.status).toBe(409);
    expect(s.pushes.some((p) => p.msg.type === "changed")).toBe(true);

    const full = await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
    expect(full.variables).toHaveLength(1);
    expect(full.envelopes).toHaveLength(1);
    expect(full.manager.devices).toHaveLength(1);
    expect(full.manager.recovery.generation).toBe("1");

    await s.ok("DELETE", `/api/v1/environments/${env}/variables/OPENAI_API_KEY`, {
      token: a.phone.token,
      headers: { "idempotency-key": newId() },
    });
    const inc = await s.ok("GET", `/api/v1/sync?since=${full.seq}`, { token: a.phone.token });
    expect(inc.variables).toEqual([expect.objectContaining({ name: "OPENAI_API_KEY", deleted: true })]);
    const fresh = await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
    expect(fresh.variables).toHaveLength(0);
    expect((await put(s, a.phone.token, env, "1BAD")).status).toBe(400);
    expect((await put(s, a.phone.token, env, "__HARMONIA_X")).status).toBe(400);
  });
});

describe("配对与权限", () => {
  it("配对、授权、只读拒写、降权、到期与撤销", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const env = await a.createEnv(s, [a.phone.id]);
    const other = await a.createEnv(s, [a.phone.id], "其他");
    expect((await put(s, a.phone.token, env, "EXISTING")).status).toBe(200);

    const cli = await pairClient(s, a, [{ envId: env, role: "rw" }]);
    const sync = await s.ok("GET", "/api/v1/sync?since=0", { token: cli.token });
    expect(sync.environments.map((e: { id: string }) => e.id)).toEqual([env]);
    expect(sync.variables.map((v: { name: string }) => v.name)).toEqual(["EXISTING"]);
    expect(sync.manager).toBeUndefined();
    expect((await put(s, cli.token, env, "FROM_CLI")).status).toBe(200);
    expect((await put(s, cli.token, other, "NOPE")).status).toBe(403);
    expect((await s.call("POST", "/api/v1/pairings/x/approve", { token: cli.token, body: {} })).status).toBe(403);

    // 降为只读：写入立即被拒绝。
    await s.ok("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ envId: env, role: "ro", expiresAt: 0 }], envelopes: [] },
    });
    expect((await put(s, cli.token, env, "X")).status).toBe(403);

    // 新增授权必须带封装。
    const missing = await s.call("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ envId: env, role: "ro" }, { envId: other, role: "rw" }], envelopes: [] },
    });
    expect(missing.status).toBe(400);
    const before = await s.ok("GET", "/api/v1/sync?since=0", { token: cli.token });
    await s.ok("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: {
        grants: [{ envId: env, role: "ro" }, { envId: other, role: "rw", expiresAt: s.clock + 60_000 }],
        envelopes: [await a.envelope(other, cli.id)],
      },
    });
    const after = await s.ok("GET", `/api/v1/sync?since=${before.seq}`, { token: cli.token });
    expect(after.environments).toHaveLength(2);

    // 到期后不再可见。
    s.clock += 120_000;
    await cli.login(s, a.accountId);
    const expired = await s.ok("GET", "/api/v1/sync?since=0", { token: cli.token });
    expect(expired.environments.map((e: { id: string }) => e.id)).toEqual([env]);

    // 撤销后无法再登录。
    await s.ok("POST", `/api/v1/devices/${cli.id}/revoke`, { token: a.phone.token });
    expect(s.pushes.some((p) => p.msg.type === "revoked")).toBe(true);
    expect((await s.call("GET", "/api/v1/sync?since=0", { token: cli.token })).status).toBe(401);
    const relogin = await s.call("POST", "/api/v1/auth/challenge", {
      body: { deviceId: cli.id },
      headers: { "x-harmonia-account": a.accountId },
    });
    expect(relogin.json.error).toBe("device_revoked");
  });

  it("账号公钥不一致时拒绝配对；配对码只能用一次", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const pw = await a.passwordLogin(s);
    const fake = await Ed.create();
    const r = await s.call("POST", "/api/v1/pairings", {
      token: pw.token,
      body: { name: "x", platform: "linux", signPub: fake.pub, boxPub: b64(rand(32)), rootPub: fake.pub, canManage: false },
    });
    expect(r.status).toBe(409);
    const cli = await pairClient(s, a, []);
    const again = await s.call("POST", `/api/v1/pairings/${cli.id}/approve`, { token: a.phone.token, body: {} });
    expect(again.status).toBe(409);
  });

  it("第二台管理设备需要全部环境的封装；不能撤销最后一台管理设备", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const env = await a.createEnv(s, [a.phone.id]);
    expect((await s.call("POST", `/api/v1/devices/${a.phone.id}/revoke`, { token: a.phone.token })).status).toBe(409);
    expect((await s.call("POST", "/api/v1/devices/self/revoke", { token: a.phone.token, body: {} })).status).toBe(409);

    const phone2 = await FakeDevice.create();
    const pw = await a.passwordLogin(s);
    const req = await s.ok("POST", "/api/v1/pairings", {
      token: pw.token,
      body: { name: "新手机", platform: "android", signPub: phone2.sign.pub, boxPub: phone2.boxPub, rootPub: a.root.pub, canManage: true },
    });
    phone2.id = req.id;
    await waitApproval(s, a, req);
    const incomplete = await s.call("POST", `/api/v1/pairings/${req.id}/approve`, {
      token: a.phone.token,
      body: { kind: "manager", cert: await a.cert(phone2, "manager"), rootSealed: b64(rand(80)), envelopes: [] },
    });
    expect(incomplete.status).toBe(400);
    await s.ok("POST", `/api/v1/pairings/${req.id}/approve`, {
      token: a.phone.token,
      body: {
        kind: "manager",
        cert: await a.cert(phone2, "manager"),
        rootSealed: b64(rand(80)),
        envelopes: [await a.envelope(env, phone2.id)],
      },
    });
    await phone2.login(s, a.accountId);
    const sync = await s.ok("GET", "/api/v1/sync?since=0", { token: phone2.token });
    expect(sync.manager.devices).toHaveLength(2);
    // 现在有两台管理设备，新环境必须同时封装给两台。
    expect(
      (
        await s.call("POST", "/api/v1/environments", {
          token: a.phone.token,
          body: { id: newId(), name: "y", envelopes: [] },
        })
      ).status,
    ).toBe(400);
    await s.ok("POST", `/api/v1/devices/${a.phone.id}/revoke`, { token: phone2.token });
  });
});

describe("恢复", () => {
  it("凭恢复码登记新手机，必须先轮换恢复码；旧恢复码随即失效", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const env = await a.createEnv(s, [a.phone.id]);

    const start = async (signer: Ed) => {
      const ch = await s.ok("POST", "/api/v1/recovery/challenge", { body: { email: a.email } });
      expect(ch.accountId).toBe(a.accountId);
      return s.call("POST", "/api/v1/recovery/session", {
        body: { nonce: ch.nonce, signature: await signer.sign(recoveryAuthMsg(ch.nonce)) },
        headers: { "x-harmonia-account": a.accountId },
      });
    };
    expect((await start(await Ed.create())).status).toBe(401);
    const rs = await start(a.recovery);
    expect(rs.status).toBe(200);
    const material = await s.ok("GET", "/api/v1/recovery/material", { token: rs.json.token });
    expect(material.rootPub).toBe(a.root.pub);
    expect(material.envelopes).toHaveLength(1);

    const phone2 = await FakeDevice.create();
    await s.ok("POST", "/api/v1/recovery/enroll", {
      token: rs.json.token,
      body: {
        device: {
          id: phone2.id,
          name: "新手机",
          platform: "android",
          signPub: phone2.sign.pub,
          boxPub: phone2.boxPub,
          cert: await a.cert(phone2, "manager"),
        },
        rootSealed: b64(rand(80)),
        envelopes: [await a.envelope(env, phone2.id)],
      },
    });
    expect((await s.call("GET", "/api/v1/recovery/material", { token: rs.json.token })).status).toBe(401);
    await phone2.login(s, a.accountId);
    expect((await s.ok("GET", "/api/v1/sync?since=0", { token: phone2.token })).self.rotationRequired).toBe(true);
    expect((await put(s, phone2.token, env, "BLOCKED")).json.error).toBe("rotation_required");

    const newRec = await Ed.create();
    const sealed = b64(rand(80));
    const key = newId();
    const newAuth = b64(rand(32));
    const rotate = {
      idempotencyKey: key,
      generation: "2",
      signPub: newRec.pub,
      boxPub: b64(rand(32)),
      rootEnvelope: { sealed, sig: await newRec.sign(await rootRecoveryMsg(2, sealed)) },
      envelopes: [await a.envelope(env, "recovery")],
      password: { kdfSalt: b64(rand(16)), authKey: newAuth },
    };
    expect((await s.ok("GET", `/api/v1/recovery/rotate/${key}`, { token: phone2.token })).state).toBe("absent");
    await s.ok("POST", "/api/v1/recovery/rotate", { token: phone2.token, body: rotate });
    const replay = await s.ok("POST", "/api/v1/recovery/rotate", { token: phone2.token, body: rotate });
    expect(replay.generation).toBe("2");
    expect((await s.ok("GET", `/api/v1/recovery/rotate/${key}`, { token: phone2.token })).state).toBe("complete");
    expect((await put(s, phone2.token, env, "OK")).status).toBe(200);
    expect((await start(a.recovery)).status).toBe(401);
    expect((await start(newRec)).status).toBe(200);
    await s.ok("POST", "/api/v1/auth/login", { body: { email: a.email, authKey: newAuth } });
  });
});
