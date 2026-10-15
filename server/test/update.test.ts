import { describe, expect, it } from "vitest";
import { pairClient, TestAccount, TestServer } from "./helpers";

describe("自动更新开关", () => {
  it("默认关闭；管理设备和设备本身都能修改，改后推送 changed", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const cli = await pairClient(s, a, [{ envId: e1, role: "ro" }]);
    const self = async () => (await s.ok("GET", "/api/v1/sync?since=0", { token: cli.token })).self;
    const seen = async () =>
      (await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token })).manager.devices.find((d: { id: string }) => d.id === cli.id);
    expect((await self()).autoUpdate).toBe(false);
    expect((await seen()).autoUpdate).toBe(false);

    const pushes = s.pushes.length;
    await s.ok("PATCH", "/api/v1/devices/self", { token: cli.token, body: { autoUpdate: true } });
    expect(s.pushes.slice(pushes).some((p) => p.target === "all" && p.msg.type === "changed")).toBe(true);
    expect((await self()).autoUpdate).toBe(true);
    expect((await seen()).autoUpdate).toBe(true);

    await s.ok("PATCH", `/api/v1/devices/${cli.id}`, { token: a.phone.token, body: { autoUpdate: false } });
    expect(await self()).toMatchObject({ autoUpdate: false, systemVars: false });

    const wrong = await s.call("PATCH", "/api/v1/devices/self", { token: cli.token, body: { autoUpdate: 1 } });
    expect(wrong.status).toBe(400);
  });
});

describe("让电脑更新", () => {
  it("只有管理设备能发起；只推送给在线的那台电脑；不在线时返回 device_offline", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const cli = await pairClient(s, a, [{ envId: e1, role: "ro" }]);
    const other = await pairClient(s, a, [{ envId: e1, role: "ro" }]);
    const path = `/api/v1/devices/${cli.id}/update`;

    const offline = await s.call("POST", path, { token: a.phone.token });
    expect(offline.status).toBe(409);
    expect(offline.json.error).toBe("device_offline");

    s.online.add(cli.id);
    const pushes = s.pushes.length;
    expect(await s.ok("POST", path, { token: a.phone.token })).toEqual({});
    expect(s.pushes.slice(pushes).map((p) => [p.target, p.msg])).toEqual([[{ device: cli.id }, { type: "update" }]]);

    expect((await s.call("POST", path, { token: other.token })).status).toBe(403);
    expect((await s.call("POST", `/api/v1/devices/${a.phone.id}/update`, { token: a.phone.token })).status).toBe(400);
    expect((await s.call("POST", "/api/v1/devices/AAAAAAAAAAAAAAAAAAAAAA/update", { token: a.phone.token })).status).toBe(404);
  });

  it("上报的版本变化时通知管理设备，版本不变时不通知", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const e1 = await a.createEnv(s, [a.phone.id], "A");
    const cli = await pairClient(s, a, [{ envId: e1, role: "ro" }]);
    const sync = (version: string) =>
      s.ok("GET", "/api/v1/sync?since=0", { token: cli.token, headers: { "x-harmonia-version": version } });
    const notified = () => s.pushes.filter((p) => p.target === "managers" && p.msg.type === "changed").length;

    await sync("0.9.0");
    const before = notified();
    const seqBefore = (await sync("0.9.0")).seq;
    expect(notified()).toBe(before);
    const after = await sync("0.10.0");
    expect(notified()).toBe(before + 1);
    // 本次响应的 seq 已经包含版本变化，电脑自己不会因此再同步一次。
    expect(after.seq).toBe(seqBefore + 1);
  });
});
