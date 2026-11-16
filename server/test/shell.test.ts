import { describe, expect, it } from "vitest";
import { pairClient, TestAccount, TestServer } from "./helpers";

describe("设备 Shell 集成", () => {
  it("默认关闭；手机和本机共用开关，执行回执区分待同步与生效", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const cli = await pairClient(s, a, []);
    const self = async () => (await s.ok("GET", "/api/v1/sync?since=0", { token: cli.token })).self;
    const seen = async () => (await s.ok("GET", "/api/v1/sync?since=0", { token: a.phone.token })).manager.devices.find((d: { id: string }) => d.id === cli.id);
    const report = (enabled: boolean, error: string | null = null) => s.ok("POST", "/api/v1/devices/self/shell-state", { token: cli.token, body: { enabled, error } });
    expect(await self()).toMatchObject({ shellEnabled: false, shellState: null });
    await report(false);
    expect((await seen()).shellState).toEqual({ enabled: false, error: null });
    await s.ok("PATCH", `/api/v1/devices/${cli.id}`, { token: a.phone.token, body: { shellEnabled: true } });
    expect(await self()).toMatchObject({ shellEnabled: true, shellState: null });
    await report(false);
    expect((await seen()).shellState).toBeNull();
    await report(true, "请在电脑上重新安装 Shell 集成。");
    expect((await seen()).shellState.error).toContain("重新安装");
    await report(true);
    expect((await seen()).shellState).toEqual({ enabled: true, error: null });
    const before = s.pushes.length;
    await report(true);
    expect(s.pushes.length).toBe(before);
    await s.ok("PATCH", "/api/v1/devices/self", { token: cli.token, body: { shellEnabled: false } });
    expect(await seen()).toMatchObject({ shellEnabled: false, shellState: null });
    await report(false);
    expect((await seen()).shellState).toEqual({ enabled: false, error: null });
  });

  it("校验开关和回执；电脑不能控制其他设备，手机不能伪造回执", async () => {
    const s = new TestServer();
    const a = await TestAccount.create(s);
    const cli = await pairClient(s, a, []);
    const other = await pairClient(s, a, []);
    expect((await s.call("PATCH", `/api/v1/devices/${cli.id}`, { token: other.token, body: { shellEnabled: true } })).status).toBe(403);
    expect((await s.call("PATCH", "/api/v1/devices/self", { token: a.phone.token, body: { shellEnabled: true } })).status).toBe(400);
    expect((await s.call("PATCH", "/api/v1/devices/self", { token: cli.token, body: { shellEnabled: 1 } })).status).toBe(400);
    expect((await s.call("POST", "/api/v1/devices/self/shell-state", { token: a.phone.token, body: { enabled: true, error: null } })).status).toBe(403);
    for (const body of [{ enabled: 1, error: null }, { enabled: true }, { enabled: true, error: "x".repeat(501) }]) {
      expect((await s.call("POST", "/api/v1/devices/self/shell-state", { token: cli.token, body })).status).toBe(400);
    }
  });
});
