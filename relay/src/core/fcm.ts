// FCM：HTTP v1 接口，用服务账号签 RS256 的 JWT 换取 OAuth 令牌（docs/protocol.md 5.2）。
import { signJwt } from "./jwt";
import type { Message } from "./messages";
import type { Registration } from "./registry";
import type { Fetch, SendResult, Sender } from "./sender";

export type ServiceAccount = { client_email: string; private_key: string; project_id: string; token_uri: string };

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
/** Android 上的通知渠道，与 App 中创建的一致。 */
export const ANDROID_CHANNEL = "approvals";

export function parseServiceAccount(json: string): ServiceAccount {
  const v = JSON.parse(json) as Partial<ServiceAccount>;
  if (!v.client_email || !v.private_key || !v.project_id) throw new Error("FCM_SERVICE_ACCOUNT 缺少 client_email、private_key 或 project_id");
  return { client_email: v.client_email, private_key: v.private_key, project_id: v.project_id, token_uri: v.token_uri ?? "https://oauth2.googleapis.com/token" };
}

export function fcmMessage(reg: Registration, msg: Message) {
  return {
    message: {
      token: reg.token,
      notification: { title: msg.title, body: msg.body },
      android: {
        priority: "HIGH",
        ttl: `${msg.ttl}s`,
        collapse_key: msg.type,
        notification: { channel_id: ANDROID_CHANNEL, tag: msg.type },
      },
    },
  };
}

/** UNREGISTERED 表示推送令牌已失效，删除登记。 */
export function classifyFcm(status: number, body: unknown): SendResult {
  if (status === 200) return "ok";
  const details = (body as { error?: { details?: { errorCode?: string }[] } })?.error?.details ?? [];
  return details.some((d) => d.errorCode === "UNREGISTERED") ? "gone" : "failed";
}

export class Fcm implements Sender {
  private token: { value: string; expiresAt: number } | null = null;

  constructor(
    private account: ServiceAccount,
    private fetcher: Fetch = (u, i) => fetch(u, i),
    private now: () => number = Date.now,
  ) {}

  private async accessToken(): Promise<string> {
    const now = this.now();
    if (this.token && now < this.token.expiresAt - 60_000) return this.token.value;
    const iat = Math.floor(now / 1000);
    const assertion = await signJwt("RS256", this.account.private_key, {}, {
      iss: this.account.client_email,
      scope: SCOPE,
      aud: this.account.token_uri,
      iat,
      exp: iat + 3600,
    });
    const res = await this.fetcher(this.account.token_uri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
    });
    if (!res.ok) throw new Error(`换取 FCM 访问令牌失败：${res.status}`);
    const v = (await res.json()) as { access_token: string; expires_in: number };
    this.token = { value: v.access_token, expiresAt: now + v.expires_in * 1000 };
    return v.access_token;
  }

  async send(reg: Registration, msg: Message): Promise<SendResult> {
    let res: Response;
    try {
      res = await this.fetcher(`https://fcm.googleapis.com/v1/projects/${this.account.project_id}/messages:send`, {
        method: "POST",
        headers: { authorization: `Bearer ${await this.accessToken()}`, "content-type": "application/json" },
        body: JSON.stringify(fcmMessage(reg, msg)),
      });
    } catch (e) {
      console.error("FCM 请求失败", e);
      return "failed";
    }
    if (res.status === 401) this.token = null;
    const result = classifyFcm(res.status, res.status === 200 ? null : await res.json().catch(() => null));
    if (result === "failed") console.error(`FCM 返回 ${res.status}`);
    return result;
  }
}
