import { describe, expect, it } from "vitest";
import { pairClient, TestAccount, TestServer } from "./helpers";

type SyncEnv = { id: string; active: boolean; position: number };

const syncEnvs = async (s: TestServer, token: string) =>
  ((await s.ok("GET", "/api/v1/sync?since=0", { token })).environments as SyncEnv[]).map((e) => [e.id, e.active, e.position]);

describe("激活状态与顺序", () => {
  it("新授权默认激活并排在最后；修改角色保留激活状态和顺序", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const e2 = await a.createEnv(s, [a.phone.id], "B");
    const cli = await pairClient(s, a, [{ envId: e1, role: "ro" }, { envId: e2, role: "ro" }]);
    expect(await syncEnvs(s, cli.token)).toEqual([
      [e1, true, 0],
      [e2, true, 1],
    ]);

    await s.ok("PUT", "/api/v1/devices/self/activation", {
      token: cli.token,
      body: { envs: [{ envId: e2, active: true }, { envId: e1, active: false }] },
    });
    await s.ok("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ envId: e1, role: "rw", expiresAt: 0 }, { envId: e2, role: "ro", expiresAt: 0 }], envelopes: [] },
    });
    expect(await syncEnvs(s, cli.token)).toEqual([
      [e2, true, 0],
      [e1, false, 1],
    ]);

    // 管理设备看到同样的状态。
    const m = await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
    const grants = m.manager.devices.find((d: { id: string }) => d.id === cli.id).grants;
    expect(grants.map((g: { envId: string; active: boolean }) => [g.envId, g.active])).toEqual([
      [e2, true],
      [e1, false],
    ]);
  });

  it("管理设备可以修改任何设备；客户端设备只能修改自己；列表必须与授权一致", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const e2 = await a.createEnv(s, [a.phone.id], "B");
    const cli = await pairClient(s, a, [{ envId: e1, role: "ro" }, { envId: e2, role: "ro" }]);
    const other = await pairClient(s, a, [{ envId: e1, role: "ro" }]);

    const pushes = s.pushes.length;
    await s.ok("PUT", `/api/v1/devices/${cli.id}/activation`, {
      token: a.phone.token,
      body: { envs: [{ envId: e1, active: false }, { envId: e2, active: true }] },
    });
    expect(s.pushes.slice(pushes).some((p) => p.msg.type === "changed")).toBe(true);
    expect(await syncEnvs(s, cli.token)).toEqual([
      [e1, false, 0],
      [e2, true, 1],
    ]);

    const byOther = await s.call("PUT", `/api/v1/devices/${cli.id}/activation`, {
      token: other.token,
      body: { envs: [{ envId: e1, active: true }, { envId: e2, active: true }] },
    });
    expect(byOther.status).toBe(403);
    const missing = await s.call("PUT", "/api/v1/devices/self/activation", {
      token: cli.token,
      body: { envs: [{ envId: e1, active: true }] },
    });
    expect([missing.status, missing.json.error]).toEqual([409, "conflict"]);
    const manager = await s.call("PUT", "/api/v1/devices/self/activation", { token: a.phone.token, body: { envs: [] } });
    expect(manager.status).toBe(400);
  });

  it("未到期的授权必须全部列出，已到期的可以省略并排在后面", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const e2 = await a.createEnv(s, [a.phone.id], "B");
    const e3 = await a.createEnv(s, [a.phone.id], "C");
    const cli = await pairClient(s, a, [
      { envId: e1, role: "ro", expiresAt: s.clock + 1000 },
      { envId: e2, role: "ro" },
      { envId: e3, role: "ro" },
    ]);
    s.clock += 2000;
    await s.ok("PUT", "/api/v1/devices/self/activation", {
      token: cli.token,
      body: { envs: [{ envId: e3, active: true }, { envId: e2, active: false }] },
    });
    const m = await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token });
    const grants = m.manager.devices.find((d: { id: string }) => d.id === cli.id).grants;
    expect(grants.map((g: { envId: string; position: number }) => [g.envId, g.position])).toEqual([
      [e3, 0],
      [e2, 1],
      [e1, 2],
    ]);
    const partial = await s.call("PUT", "/api/v1/devices/self/activation", {
      token: cli.token,
      body: { envs: [{ envId: e3, active: true }] },
    });
    expect(partial.status).toBe(409);
  });

  it("撤销授权后顺序重新编号", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const e2 = await a.createEnv(s, [a.phone.id], "B");
    const e3 = await a.createEnv(s, [a.phone.id], "C");
    const cli = await pairClient(s, a, [
      { envId: e1, role: "ro" },
      { envId: e2, role: "ro" },
      { envId: e3, role: "ro" },
    ]);
    await s.ok("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ envId: e1, role: "ro", expiresAt: 0 }, { envId: e3, role: "ro", expiresAt: 0 }], envelopes: [] },
    });
    expect(await syncEnvs(s, cli.token)).toEqual([
      [e1, true, 0],
      [e3, true, 1],
    ]);
  });
});
