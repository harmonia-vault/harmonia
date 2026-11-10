// 通知内容：由中继按类型生成，实例不能指定文字（docs/protocol.md 5.2）。

export type NotifyType = "approval" | "pairing";

export type Message = {
  type: NotifyType;
  title: string;
  body: string;
  /** 有效期（秒），等于请求本身的有效期：过了这个时间手机才联网就不再送达。 */
  ttl: number;
};

const MESSAGES: Record<NotifyType, Message> = {
  approval: { type: "approval", title: "Harmonia", body: "有一个待批准的请求，打开 App 查看", ttl: 120 },
  pairing: { type: "pairing", title: "Harmonia", body: "有设备请求接入，打开 App 查看", ttl: 300 },
};

export function message(type: unknown): Message | null {
  return typeof type === "string" && Object.hasOwn(MESSAGES, type) ? MESSAGES[type as NotifyType] : null;
}
