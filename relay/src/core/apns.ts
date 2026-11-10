// APNs：HTTP/2 接口，用 .p8 密钥签 ES256 的 JWT（docs/protocol.md 5.2）。
import { signJwt } from "./jwt";
import type { Message } from "./messages";
import type { Registration } from "./registry";
import type { Fetch, SendResult, Sender } from "./sender";

export type ApnsConfig = { key: string; keyId: string; teamId: string; topic: string };

/** 苹果要求令牌在 20 到 60 分钟之间更换。 */
const TOKEN_TTL = 40 * 60_000;
/** 推送令牌失效，删除登记。 */
const GONE = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

export function apnsRequest(reg: Registration, msg: Message, jwt: string, topic: string, now: number) {
  const host = reg.apnsEnv === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return {
    url: `https://${host}/3/device/${reg.token}`,
    init: {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(now / 1000) + msg.ttl),
        "apns-collapse-id": msg.type,
        "apns-topic": topic,
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { alert: { title: msg.title, body: msg.body }, sound: "default" } }),
    } satisfies RequestInit,
  };
}

/** 按状态码和 reason 归类。providerTokenBad 表示我们的 JWT 有问题，需要换一个。 */
export function classifyApns(status: number, reason: string | undefined): { result: SendResult; providerTokenBad: boolean } {
  if (status === 200) return { result: "ok", providerTokenBad: false };
  if (status === 410 || (reason && GONE.has(reason))) return { result: "gone", providerTokenBad: false };
  return { result: "failed", providerTokenBad: reason === "ExpiredProviderToken" || reason === "InvalidProviderToken" };
}

export class Apns implements Sender {
  private token: { jwt: string; at: number } | null = null;

  constructor(
    private cfg: ApnsConfig,
    private fetcher: Fetch = (u, i) => fetch(u, i),
    private now: () => number = Date.now,
  ) {}

  private async jwt(): Promise<string> {
    const now = this.now();
    if (this.token && now - this.token.at < TOKEN_TTL) return this.token.jwt;
    const jwt = await signJwt("ES256", this.cfg.key, { kid: this.cfg.keyId }, { iss: this.cfg.teamId, iat: Math.floor(now / 1000) });
    this.token = { jwt, at: now };
    return jwt;
  }

  async send(reg: Registration, msg: Message): Promise<SendResult> {
    const { url, init } = apnsRequest(reg, msg, await this.jwt(), this.cfg.topic, this.now());
    let res: Response;
    try {
      res = await this.fetcher(url, init);
    } catch (e) {
      console.error("APNs 请求失败", e);
      return "failed";
    }
    const reason = res.status === 200 ? undefined : ((await res.json().catch(() => ({}))) as { reason?: string }).reason;
    const { result, providerTokenBad } = classifyApns(res.status, reason);
    if (providerTokenBad) this.token = null;
    if (result === "failed") console.error(`APNs 返回 ${res.status} ${reason ?? ""}`);
    return result;
  }
}
