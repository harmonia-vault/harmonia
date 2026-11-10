// 系统通知：登记推送句柄，有新请求时经推送中继通知管理设备（docs/protocol.md 3.10）。
import type { Hono } from "hono";
import { readJson, requireDevice, type Deps } from "./context";
import { one } from "./db";
import { bad, forbidden } from "./util";

/** 推送中继的地址：句柄只在登记它的中继上有效，必须和 App 中的一致，不做成配置（设计文档 18.6）。 */
export const RELAY_URL = "https://harmonia-push.zzz.sd";

export type NotifyType = "approval" | "pairing";

/** 发出结果：gone 表示句柄已失效（中继答复 not_found），其他失败一律忽略。 */
export type NotifyResult = "ok" | "gone" | "failed";

export interface PushRelay {
  /** 部署变量 PUSH_NOTIFICATIONS 不为 false 时开启。 */
  enabled: boolean;
  notify(handle: string, type: NotifyType): Promise<NotifyResult>;
  remove(handle: string): Promise<void>;
  /** 让发送在响应之后继续进行，不拖慢请求。 */
  defer(task: Promise<unknown>): void;
}

const HANDLE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** 中继客户端：超时 10 秒，失败不重试。 */
export function relayClient(base: string, fetcher: typeof fetch = fetch) {
  const call = async (method: string, path: string, handle: string, body?: unknown) =>
    fetcher(`${base}/api/v1${path}`, {
      method,
      headers: { authorization: `Bearer ${handle}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
  return {
    notify: async (handle: string, type: NotifyType): Promise<NotifyResult> => {
      try {
        const res = await call("POST", "/notify", handle, { type });
        if (res.ok) return "ok";
        const err = ((await res.json().catch(() => ({}))) as { error?: string }).error;
        return err === "not_found" ? "gone" : "failed";
      } catch {
        return "failed";
      }
    },
    remove: async (handle: string) => {
      try {
        await call("DELETE", "/registration", handle);
      } catch {
        // 尽力而为：中继 90 天后也会清理没有确认的登记。
      }
    },
  };
}

/**
 * 新的批准请求或配对请求出现时调用：发给登记了句柄、不需要轮换恢复码的有效管理设备。
 * 不按事件连接判断前后台；App 在前台时自行隐藏通知横幅。
 */
export function sendRequestNotifications(deps: Deps, type: NotifyType) {
  const push = deps.push;
  if (!push?.enabled) return;
  const targets = deps.sql.all<{ id: string; push_handle: string }>(
    `SELECT id, push_handle FROM devices WHERE kind = 'manager' AND status = 'active' AND rotation_required = 0 AND push_handle IS NOT NULL`,
  );
  for (const t of targets) {
    push.defer(
      push.notify(t.push_handle, type).then((r) => {
        if (r === "gone") deps.sql.run(`UPDATE devices SET push_handle = NULL WHERE id = ? AND push_handle = ?`, t.id, t.push_handle);
      }),
    );
  }
}

/** 让中继删除登记，不等答复。 */
function removeAtRelay(deps: Deps, handle: string) {
  if (deps.push) deps.push.defer(deps.push.remove(handle));
}

/** 设备被撤销、本机退出时删除句柄，并尽力通知中继删除登记。在撤销的事务之前调用。 */
export function dropHandle(deps: Deps, deviceId: string) {
  const row = one<{ push_handle: string | null }>(deps.sql, `SELECT push_handle FROM devices WHERE id = ?`, deviceId);
  if (!row?.push_handle) return;
  deps.sql.run(`UPDATE devices SET push_handle = NULL WHERE id = ?`, deviceId);
  removeAtRelay(deps, row.push_handle);
}

export function pushRoutes(app: Hono, deps: Deps) {
  app.put("/api/v1/devices/self/push", async (c) => {
    const d = await requireDevice(c, deps, { manager: true });
    if (!deps.push?.enabled) throw forbidden("这台服务器关闭了后台通知");
    const handle = (await readJson(c)).handle;
    if (typeof handle !== "string" || !HANDLE_PATTERN.test(handle)) throw bad("推送句柄格式不对，请在 App 中重新开启后台通知。");
    const old = d.push_handle;
    deps.sql.run(`UPDATE devices SET push_handle = ? WHERE id = ?`, handle, d.id);
    if (old && old !== handle) removeAtRelay(deps, old);
    return c.json({});
  });

  app.delete("/api/v1/devices/self/push", async (c) => {
    const d = await requireDevice(c, deps, { manager: true });
    deps.sql.run(`UPDATE devices SET push_handle = NULL WHERE id = ?`, d.id);
    return c.json({});
  });
}
