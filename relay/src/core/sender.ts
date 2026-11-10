// 把通知交给 APNs 或 FCM。
import type { Message } from "./messages";
import type { Registration } from "./registry";

/** ok：已交给苹果或谷歌；gone：推送令牌已失效，删除登记；failed：暂时失败。 */
export type SendResult = "ok" | "gone" | "failed";

export interface Sender {
  send(reg: Registration, msg: Message): Promise<SendResult>;
}

export type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/** 按平台分派。某个平台没有配置凭据时，发往这个平台的通知按暂时失败处理。 */
export function platformSender(senders: { ios?: Sender; android?: Sender }): Sender {
  return {
    send: async (reg, msg) => {
      const s = reg.platform === "ios" ? senders.ios : senders.android;
      if (!s) {
        console.error(`没有配置 ${reg.platform} 的推送凭据`);
        return "failed";
      }
      return s.send(reg, msg);
    },
  };
}
