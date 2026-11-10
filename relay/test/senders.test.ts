import { describe, expect, it } from "vitest";
import { Apns, apnsRequest, classifyApns } from "../src/core/apns";
import { classifyFcm, Fcm, fcmMessage } from "../src/core/fcm";
import { message } from "../src/core/messages";
import { decodeJwt, testKey } from "./helpers";

const NOW = 1_800_000_000_000;
const approval = message("approval")!;
const pairing = message("pairing")!;

describe("通知内容", () => {
  it("只有两种类型，文案固定、不带任何数据，有效期等于请求有效期", () => {
    expect(approval).toEqual({ type: "approval", title: "Harmonia", body: "有一个待批准的请求，打开 App 查看", ttl: 120 });
    expect(pairing.ttl).toBe(300);
    expect(message("changed")).toBeNull();
    expect(message("toString")).toBeNull();
  });
});

describe("APNs", () => {
  const reg = { platform: "ios" as const, token: "ab".repeat(32), apnsEnv: "production" as const };

  it("请求头和载荷符合协议 5.2，按环境选择主机", () => {
    const { url, init } = apnsRequest(reg, approval, "JWT", "org.harmoniavault.harmonia", NOW);
    expect(url).toBe(`https://api.push.apple.com/3/device/${reg.token}`);
    expect(init.headers).toMatchObject({
      authorization: "bearer JWT",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(NOW / 1000 + 120),
      "apns-collapse-id": "approval",
      "apns-topic": "org.harmoniavault.harmonia",
    });
    expect(JSON.parse(init.body)).toEqual({ aps: { alert: { title: "Harmonia", body: approval.body }, sound: "default" } });
    expect(apnsRequest({ ...reg, apnsEnv: "sandbox" }, approval, "JWT", "t", NOW).url).toContain("api.sandbox.push.apple.com");
  });

  it("令牌失效的答复归为 gone，令牌问题以外的错误归为 failed", () => {
    expect(classifyApns(200, undefined).result).toBe("ok");
    for (const r of ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]) expect(classifyApns(400, r).result).toBe("gone");
    expect(classifyApns(410, "Unregistered").result).toBe("gone");
    expect(classifyApns(429, "TooManyRequests").result).toBe("failed");
    expect(classifyApns(403, "ExpiredProviderToken")).toEqual({ result: "failed", providerTokenBad: true });
  });

  it("用 .p8 签 ES256 的 JWT，40 分钟内复用，被拒后换新", async () => {
    const key = await testKey("ES256");
    const seen: string[] = [];
    let status = 200;
    let t = NOW;
    const apns = new Apns(
      { key: key.pem.replace(/\n/g, "\\n"), keyId: "KEY123", teamId: "TEAM45", topic: "org.harmoniavault.harmonia" },
      async (_url, init) => {
        seen.push((init.headers as Record<string, string>).authorization!.slice("bearer ".length));
        return status === 200 ? new Response(null, { status }) : Response.json({ reason: "ExpiredProviderToken" }, { status });
      },
      () => t,
    );
    expect(await apns.send(reg, approval)).toBe("ok");
    const jwt = decodeJwt(seen[0]!);
    expect(jwt.header).toEqual({ alg: "ES256", typ: "JWT", kid: "KEY123" });
    expect(jwt.claims).toEqual({ iss: "TEAM45", iat: NOW / 1000 });
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key.publicKey, jwt.sig, new TextEncoder().encode(jwt.input));
    expect(ok).toBe(true);

    t += 30 * 60_000;
    await apns.send(reg, approval);
    expect(seen[1]).toBe(seen[0]);
    status = 403;
    expect(await apns.send(reg, approval)).toBe("failed");
    status = 200;
    t += 1000;
    await apns.send(reg, approval);
    expect(seen[3]).not.toBe(seen[0]);
  });
});

describe("FCM", () => {
  const reg = { platform: "android" as const, token: "fcm-token", apnsEnv: null };

  it("消息符合协议 5.2：高优先级、有效期、按类型合并，不带 data", () => {
    expect(fcmMessage(reg, pairing)).toEqual({
      message: {
        token: "fcm-token",
        notification: { title: "Harmonia", body: pairing.body },
        android: { priority: "HIGH", ttl: "300s", collapse_key: "pairing", notification: { channel_id: "approvals", tag: "pairing" } },
      },
    });
  });

  it("只有 UNREGISTERED 归为 gone", () => {
    expect(classifyFcm(200, null)).toBe("ok");
    expect(classifyFcm(404, { error: { details: [{ errorCode: "UNREGISTERED" }] } })).toBe("gone");
    expect(classifyFcm(400, { error: { details: [{ errorCode: "INVALID_ARGUMENT" }] } })).toBe("failed");
    expect(classifyFcm(503, null)).toBe("failed");
  });

  it("用服务账号签 RS256 的 JWT 换取访问令牌并缓存", async () => {
    const key = await testKey("RS256");
    const calls: { url: string; init: RequestInit }[] = [];
    const fcm = new Fcm(
      { client_email: "relay@example.iam.gserviceaccount.com", private_key: key.pem, project_id: "demo", token_uri: "https://oauth2.example/token" },
      async (url, init) => {
        calls.push({ url, init });
        if (url.endsWith("/token")) return Response.json({ access_token: "ACCESS", expires_in: 3600 });
        return Response.json({ name: "projects/demo/messages/1" });
      },
      () => NOW,
    );
    expect(await fcm.send(reg, approval)).toBe("ok");
    expect(await fcm.send(reg, approval)).toBe("ok");
    expect(calls.map((c) => c.url)).toEqual([
      "https://oauth2.example/token",
      "https://fcm.googleapis.com/v1/projects/demo/messages:send",
      "https://fcm.googleapis.com/v1/projects/demo/messages:send",
    ]);
    const assertion = new URLSearchParams(calls[0]!.init.body as string).get("assertion")!;
    const jwt = decodeJwt(assertion);
    expect(jwt.claims).toMatchObject({ iss: "relay@example.iam.gserviceaccount.com", aud: "https://oauth2.example/token" });
    const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key.publicKey, jwt.sig, new TextEncoder().encode(jwt.input));
    expect(ok).toBe(true);
    expect((calls[1]!.init.headers as Record<string, string>).authorization).toBe("Bearer ACCESS");
  });
});
