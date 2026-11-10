import { describe, expect, it } from "vitest";
import { LIMITS, parseRegistration, Registry } from "../src/core/registry";
import { ApiError } from "../src/core/util";
import { nodeSql } from "./helpers";

const IOS = { platform: "ios" as const, token: "ab".repeat(32), apnsEnv: "production" as const };
const ANDROID = { platform: "android" as const, token: "fcm-token:abc_123", apnsEnv: null };

function setup(globalPerMinute?: number) {
  const t = { now: 1_800_000_000_000 };
  const sql = nodeSql();
  return { t, sql, registry: new Registry(sql, () => t.now, globalPerMinute) };
}

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
    return "ok";
  } catch (e) {
    if (e instanceof ApiError) return e.code;
    throw e;
  }
}

describe("登记内容", () => {
  it("iOS 必须带 APNs 环境，令牌是十六进制并统一为小写", () => {
    expect(parseRegistration({ token: "AB".repeat(32), apnsEnvironment: "sandbox" }, "ios")).toEqual({
      platform: "ios",
      token: "ab".repeat(32),
      apnsEnv: "sandbox",
    });
    expect(() => parseRegistration({ token: "ab".repeat(32) }, "ios")).toThrow(ApiError);
    expect(() => parseRegistration({ token: "xyz", apnsEnvironment: "production" }, "ios")).toThrow(ApiError);
  });

  it("Android 不需要 APNs 环境，平台只能是 ios 或 android", () => {
    expect(parseRegistration({ token: "a:b-c_d.e" }, "android")).toEqual({ platform: "android", token: "a:b-c_d.e", apnsEnv: null });
    expect(() => parseRegistration({ token: "a b" }, "android")).toThrow(ApiError);
    expect(() => parseRegistration({ token: "abc" }, "web")).toThrow(ApiError);
    expect(() => parseRegistration({ token: "x".repeat(4097) }, "android")).toThrow(ApiError);
  });
});

describe("句柄", () => {
  it("只保存句柄的哈希；确认可以更新令牌，删除后不再可用", async () => {
    const { registry, sql } = setup();
    const handle = await registry.register(ANDROID, "net");
    expect(handle).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const rows = sql.all<{ handle_hash: string; token: string }>(`SELECT * FROM registrations`);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.handle_hash).not.toBe(handle);

    await registry.confirm(handle, { token: "new-token" });
    expect((await registry.claim(handle, "approval"))!.reg.token).toBe("new-token");

    await registry.remove(handle);
    expect(await code(registry.claim(handle, "approval"))).toBe("not_found");
    expect(await code(registry.confirm(handle, { token: "x" }))).toBe("not_found");
    await registry.remove(handle); // 不存在时也不报错
  });

  it("确认时不能改平台：iOS 的登记仍要求 APNs 环境", async () => {
    const { registry } = setup();
    const handle = await registry.register(IOS, "net");
    expect(await code(registry.confirm(handle, { token: "cd".repeat(32) }))).toBe("invalid_request");
    await registry.confirm(handle, { token: "cd".repeat(32), apnsEnvironment: "sandbox" });
    expect((await registry.claim(handle, "pairing"))!.reg).toEqual({ platform: "ios", token: "cd".repeat(32), apnsEnv: "sandbox" });
  });

  it("令牌失效后删除登记", async () => {
    const { registry } = setup();
    const handle = await registry.register(ANDROID, "net");
    const claimed = await registry.claim(handle, "approval");
    registry.forget(claimed!.hash);
    expect(await code(registry.claim(handle, "approval"))).toBe("not_found");
  });
});

describe("限流", () => {
  it("同一类通知 10 秒内只发一条，其余合并；不同类各算各的", async () => {
    const { registry, t } = setup();
    const handle = await registry.register(ANDROID, "net");
    expect(await registry.claim(handle, "approval")).not.toBeNull();
    expect(await registry.claim(handle, "approval")).toBeNull();
    expect(await registry.claim(handle, "pairing")).not.toBeNull();
    t.now += LIMITS.mergeMs;
    expect(await registry.claim(handle, "approval")).not.toBeNull();
  });

  it("每个句柄每天最多 1000 条，合并掉的不计；不同句柄互不影响", async () => {
    const { registry, t } = setup(1_000_000);
    const a = await registry.register(ANDROID, "net");
    const b = await registry.register(ANDROID, "net");
    for (let i = 0; i < LIMITS.perHandleDay; i++) {
      expect(await registry.claim(a, "approval")).not.toBeNull();
      expect(await registry.claim(a, "approval")).toBeNull();
      t.now += LIMITS.mergeMs;
    }
    expect(await code(registry.claim(a, "approval"))).toBe("rate_limited");
    expect(await registry.claim(b, "approval")).not.toBeNull();
    t.now += 24 * 60 * 60_000;
    expect(await registry.claim(a, "approval")).not.toBeNull();
  });

  it("全局每分钟上限由所有句柄共用，可以配置", async () => {
    const { registry, t } = setup(3);
    const handles = await Promise.all([1, 2, 3, 4].map(() => registry.register(ANDROID, "net")));
    for (const h of handles.slice(0, 3)) expect(await registry.claim(h, "approval")).not.toBeNull();
    expect(await code(registry.claim(handles[3]!, "approval"))).toBe("rate_limited");
    // 被限流的那次不占合并窗口：一分钟后可以马上发出
    t.now += 60_000;
    expect(await registry.claim(handles[3]!, "approval")).not.toBeNull();
  });

  it("登记按网络限制：每分钟 20 次、每天 200 次", async () => {
    const { registry, t } = setup();
    for (let i = 0; i < LIMITS.registerPerMinute; i++) await registry.register(ANDROID, "a");
    expect(await code(registry.register(ANDROID, "a"))).toBe("rate_limited");
    expect(await code(registry.register(ANDROID, "b"))).toBe("ok");
    for (let m = 1; m < LIMITS.registerPerDay / LIMITS.registerPerMinute; m++) {
      t.now += 60_000;
      for (let i = 0; i < LIMITS.registerPerMinute; i++) await registry.register(ANDROID, "a");
    }
    t.now += 60_000;
    expect(await code(registry.register(ANDROID, "a"))).toBe("rate_limited");
  });
});

describe("清理", () => {
  it("90 天没有登记或确认的登记删除，确认过的保留", async () => {
    const { registry, t } = setup();
    const idle = await registry.register(ANDROID, "net");
    const active = await registry.register(ANDROID, "net");
    t.now += LIMITS.idleMs - 60_000;
    await registry.confirm(active, { token: "t" });
    t.now += 2 * 60 * 60_000;
    registry.sweep();
    expect(await code(registry.claim(idle, "approval"))).toBe("not_found");
    expect(await registry.claim(active, "approval")).not.toBeNull();
  });
});
