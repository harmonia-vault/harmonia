import { describe, expect, it } from "vitest";
import { APPROVAL_KEY, checkApprovalWaiters } from "../src/core/approvals";
import { approvalGrantMsg, approvalRequestMsg, b64 } from "../src/core/util";
import { FakeDevice, newId, pairClient, rand, TestAccount, TestServer } from "./helpers";

const put = (s: TestServer, token: string, vault: string, name: string) =>
  s.ok("PUT", `/api/v1/vaults/${vault}/variables/${name}`, {
    token,
    body: { value: b64(rand(60)), keyVersion: "1" },
    headers: { "idempotency-key": newId() },
  });

/** 变量库“共享”（TOKEN、MODEL），环境“生产”引用全部变量并可以修改；电脑被授权读写、没有开启本机解密。 */
async function setup(localDecrypt = false, role = "rw") {
  const s = new TestServer();
  const a = await TestAccount.create(s);
  const vault = await a.createVault(s, [a.phone.id], "共享");
  for (const n of ["TOKEN", "MODEL"]) await put(s, a.phone.token, vault, n);
  const env = await a.createEnvironment(s, [{ vaultId: vault, scope: "all", items: [] }], "生产");
  const cli = await pairClient(s, a, [{ environmentId: env, role, localDecrypt }], localDecrypt ? [vault] : []);
  return { s, a, vault, env, cli };
}

type Item = { environmentId: string; name: string; vaultId?: string };

async function request(
  s: TestServer,
  cli: FakeDevice,
  opts: { kind?: "read" | "write"; items: Item[]; del?: Item[]; payload?: string; createdAt?: number; badSig?: boolean },
) {
  const id = newId();
  const kind = opts.kind ?? "read";
  const detail = JSON.stringify({
    kind,
    deviceId: cli.id,
    createdAt: opts.createdAt ?? s.clock,
    ...(kind === "read" ? { ephPub: b64(rand(32)) } : {}),
    command: "npm run dev",
    cwd: "/home/me/blog",
    items: opts.items,
    ...(opts.del ? { delete: opts.del } : {}),
  });
  const payload = opts.payload ?? (kind === "write" ? JSON.stringify({ sealed: [{ managerId: newId(), sealed: b64(rand(80)) }] }) : "");
  const sig = await cli.sign.sign(await approvalRequestMsg(id, opts.badSig ? newId() : cli.id, detail, payload));
  const r = await s.call("POST", "/api/v1/approvals", {
    token: cli.token,
    body: { id, detail, sig, ...(payload ? { payload } : {}) },
  });
  return { id, r };
}

const wait = (s: TestServer, cli: FakeDevice, id: string) =>
  s.ok("GET", `/api/v1/approvals/${id}/events`, { token: cli.token, headers: { upgrade: "websocket" } });

describe("批准解密", () => {
  it("读取请求：核对签名和授权，等待中才出现在列表里，批准后发起方收到结果并记录授权", async () => {
    const { s, a, env, cli } = await setup();
    const items = [{ environmentId: env, name: "TOKEN" }];
    expect((await request(s, cli, { items, badSig: true })).r.status).toBe(400);
    expect((await request(s, cli, { items, createdAt: s.clock - 10 * 60_000 })).r.json.message).toContain("时间");
    expect((await request(s, cli, { items: [{ environmentId: env, name: "NOPE" }] })).r.status).toBe(400);
    const { id, r } = await request(s, cli, { items });
    expect(r.status).toBe(200);
    expect(r.json.expiresAt).toBe(s.clock + 120_000);
    expect((await s.ok("GET", "/api/v1/approvals", { token: a.phone.token })).approvals).toEqual([]);
    await wait(s, cli, id);
    const list = (await s.ok("GET", "/api/v1/approvals", { token: a.phone.token })).approvals;
    expect(list.map((x: { id: string }) => x.id)).toEqual([id]);
    expect(s.pushes.some((p) => p.target === "managers" && p.msg.type === "approval")).toBe(true);

    const sealed = b64(rand(120));
    const bad = await s.call("POST", `/api/v1/approvals/${id}/approve`, {
      token: a.phone.token,
      body: { sealed, sig: b64(rand(64)), scope: "terminal", expiresAt: s.clock + 60_000 },
    });
    expect(bad.status).toBe(400);
    const sig = await a.root.sign(await approvalGrantMsg(id, sealed));
    await s.ok("POST", `/api/v1/approvals/${id}/approve`, {
      token: a.phone.token,
      body: { sealed, sig, scope: "terminal", expiresAt: s.clock + 60_000 },
    });
    expect(s.waiters(a.accountId).messages.get(APPROVAL_KEY + id)).toEqual({ type: "approved", result: { sealed, sig } });
    expect((await s.ok("GET", `/api/v1/approvals/${id}/status`, { token: cli.token })).result).toEqual({ sealed, sig });
    const auths = (await s.ok("GET", "/api/v1/authorizations", { token: cli.token })).authorizations;
    expect(auths).toEqual([{ id, deviceId: cli.id, items, scope: "terminal", expiresAt: s.clock + 60_000 }]);
    // 已经处理过的请求不能再处理。
    expect((await s.call("POST", `/api/v1/approvals/${id}/reject`, { token: a.phone.token })).status).toBe(409);
  });

  it("开启了本机解密的环境、管理设备不需要批准", async () => {
    const { s, a, env, cli } = await setup(true);
    expect((await request(s, cli, { items: [{ environmentId: env, name: "TOKEN" }] })).r.json.message).toContain("本机解密");
    const r = await s.call("POST", "/api/v1/approvals", { token: a.phone.token, body: {} });
    expect(r.status).toBe(403);
  });

  it("拒绝、发起方离开和超时", async () => {
    const { s, a, env, cli } = await setup();
    const items = [{ environmentId: env, name: "MODEL" }];
    const w = s.waiters(a.accountId);
    const one = await request(s, cli, { items });
    await wait(s, cli, one.id);
    await s.ok("POST", `/api/v1/approvals/${one.id}/reject`, { token: a.phone.token });
    expect(w.results.get(APPROVAL_KEY + one.id)).toBe("rejected");

    const two = await request(s, cli, { items });
    await wait(s, cli, two.id);
    s.clock += 30_000;
    checkApprovalWaiters(s.deps(a.accountId), w.list());
    expect(w.results.get(APPROVAL_KEY + two.id)).toBe("left");
    expect((await s.ok("GET", `/api/v1/approvals/${two.id}/status`, { token: cli.token })).status).toBe("cancelled");
    expect((await s.call("POST", `/api/v1/approvals/${two.id}/approve`, { token: a.phone.token, body: {} })).status).toBe(409);

    const three = await request(s, cli, { items });
    await wait(s, cli, three.id);
    s.clock += 121_000;
    w.ping(APPROVAL_KEY + three.id);
    checkApprovalWaiters(s.deps(a.accountId), w.list());
    expect(w.results.get(APPROVAL_KEY + three.id)).toBe("expired");
  });

  it("写入请求：修改环境里的变量、在可以新增的变量库里新增，只读授权、不存在的变量和重复的名字被拒绝", async () => {
    const { s, a, vault, env, cli } = await setup();
    const write = (items: Item[], del?: Item[]) => request(s, cli, { kind: "write", items, del });
    expect((await write([{ environmentId: env, name: "TOKEN" }], [{ environmentId: env, name: "MODEL" }])).r.status).toBe(200);
    expect((await write([{ environmentId: env, name: "NEW_ONE", vaultId: vault }])).r.status).toBe(200);
    expect((await write([{ environmentId: env, name: "TOKEN", vaultId: vault }])).r.json.message).toContain("已经存在");
    expect((await write([{ environmentId: env, name: "NEW_TWO" }])).r.status).toBe(400);
    expect((await request(s, cli, { kind: "write", items: [{ environmentId: env, name: "TOKEN" }], payload: "{}" })).r.status).toBe(400);
    const ro = await setup(false, "ro");
    const r = await request(ro.s, ro.cli, { kind: "write", items: [{ environmentId: ro.env, name: "TOKEN" }] });
    expect(r.r.status).toBe(403);
    // 写入请求批准时没有结果。
    const { id } = await write([{ environmentId: env, name: "MODEL" }]);
    await wait(s, cli, id);
    await s.ok("POST", `/api/v1/approvals/${id}/approve`, { token: a.phone.token, body: {} });
    expect(s.waiters(a.accountId).messages.get(APPROVAL_KEY + id)).toEqual({ type: "approved", result: {} });
  });
});

describe("正在生效的授权", () => {
  async function approved(scope = "all") {
    const ctx = await setup();
    const { s, a, env, cli } = ctx;
    const { id } = await request(s, cli, { items: [{ environmentId: env, name: "TOKEN" }] });
    await wait(s, cli, id);
    const sealed = b64(rand(120));
    await s.ok("POST", `/api/v1/approvals/${id}/approve`, {
      token: a.phone.token,
      body: { sealed, sig: await a.root.sign(await approvalGrantMsg(id, sealed)), scope, expiresAt: 0 },
    });
    s.pushes = [];
    return { ...ctx, id };
  }
  const ended = (s: TestServer, id: string) => s.pushes.some((p) => p.msg.type === "authorization-ended" && p.msg.id === id);
  const list = async (s: TestServer, token: string) =>
    (await s.ok("GET", "/api/v1/authorizations", { token })).authorizations.map((x: { id: string }) => x.id);

  it("“仅这一次”不记录；长期的授权在手机上结束后通知电脑", async () => {
    const once = await approved("once");
    expect(await list(once.s, once.a.phone.token)).toEqual([]);
    const { s, a, cli, id } = await approved();
    expect(await list(s, a.phone.token)).toEqual([id]);
    await s.ok("POST", `/api/v1/authorizations/${id}/end`, { token: a.phone.token });
    expect(ended(s, id)).toBe(true);
    expect(await list(s, cli.token)).toEqual([]);
  });

  it("变量被修改、环境的引用改变、授权改为本机解密时结束", async () => {
    const changed = await approved();
    await put(changed.s, changed.a.phone.token, changed.vault, "MODEL");
    expect(ended(changed.s, changed.id)).toBe(false);
    await put(changed.s, changed.a.phone.token, changed.vault, "TOKEN");
    expect(ended(changed.s, changed.id)).toBe(true);

    const refs = await approved();
    await refs.s.ok("PUT", `/api/v1/environments/${refs.env}`, {
      token: refs.a.phone.token,
      body: { name: "生产", refs: [{ vaultId: refs.vault, scope: "pick", items: [{ name: "TOKEN" }] }], envelopes: [] },
    });
    expect(ended(refs.s, refs.id)).toBe(true);

    const local = await approved();
    await local.s.ok("PUT", `/api/v1/devices/${local.cli.id}/grants`, {
      token: local.a.phone.token,
      body: {
        grants: [{ environmentId: local.env, role: "rw", expiresAt: 0, localDecrypt: true }],
        envelopes: [await local.a.envelope(local.vault, local.cli.id)],
      },
    });
    expect(ended(local.s, local.id)).toBe(true);
  });

  it("设备被撤销时结束", async () => {
    const { s, a, cli, id } = await approved();
    await s.ok("POST", `/api/v1/devices/${cli.id}/revoke`, { token: a.phone.token });
    expect(ended(s, id)).toBe(true);
    expect(await list(s, a.phone.token)).toEqual([]);
  });
});
