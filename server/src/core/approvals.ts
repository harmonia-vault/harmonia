// 手机批准解密与写入（docs/protocol.md 3.9，设计文档 17.4）。没有开启本机解密的授权，客户端设备发起请求并保持
// 等待连接，管理设备核对后批准。服务端只转发：读取结果用请求里的临时公钥加密、由 root 签名，服务端解不开也换不了；
// 写入由管理设备解开加密给自己的那一份后自己写入。
import type { Hono } from "hono";
import { one } from "./db";
import { readJson, requireDevice, type Deps, type Device } from "./context";
import { grantedEnvs, vaultNames, type GrantedEnv } from "./access";
import { expand } from "./refs";
import { notifyInBackground } from "./push";
import {
  approvalGrantMsg,
  approvalRequestMsg,
  arr,
  bad,
  bin,
  conflict,
  forbidden,
  id,
  int,
  notFound,
  obj,
  str,
  varName,
  verifyEd25519,
} from "./util";

/** 请求 2 分钟内有效。 */
export const APPROVAL_TTL = 2 * 60_000;
/** 批准后的结果保留 2 分钟，供等待连接意外断开的发起方查询。 */
const RESULT_TTL = 2 * 60_000;
/** createdAt 与服务器时间最多相差 5 分钟。 */
const CLOCK_SKEW = 5 * 60_000;
/** 超过这么久没有收到发起方的心跳，就当作对方已经离开（与配对相同）。 */
const WAITER_TIMEOUT = 25_000;
/** 每台设备同时等待批准的请求上限。 */
const MAX_PENDING = 5;
const MAX_ITEMS = 200;
const SCOPES = ["once", "terminal", "all"] as const;
type Scope = (typeof SCOPES)[number];

/** 等待连接的键：与配对的等待连接共用一套，靠前缀区分。 */
export const APPROVAL_KEY = "approval:";

type Approval = {
  id: string;
  device_id: string;
  kind: "read" | "write";
  detail: string;
  payload: string;
  sig: string;
  status: "pending" | "approved" | "rejected" | "expired" | "cancelled";
  result: string | null;
  created_at: number;
  expires_at: number;
};

type DetailItem = { environmentId: string; name: string; vaultId?: string };
type Detail = { kind: "read" | "write"; deviceId: string; createdAt: number; items: DetailItem[]; delete: DetailItem[] };

/** 授权里的一项：环境里的名字，以及批准时它在变量库里的位置和版本。 */
type AuthItem = { environmentId: string; name: string; vaultId: string; source: string; seq: number };
type Authorization = {
  id: string;
  device_id: string;
  items: string;
  env_refs: string;
  scope: Scope;
  expires_at: number;
  created_at: number;
};

const approvalById = (deps: Deps, approvalId: string) =>
  one<Approval>(deps.sql, `SELECT * FROM approvals WHERE id = ?`, approvalId);

const waiting = (deps: Deps, approvalId: string) => deps.waiters.waiting(APPROVAL_KEY + approvalId);

function parseItems(raw: unknown, what: string): DetailItem[] {
  return arr(raw ?? [], what).map((v) => {
    const o = obj(v, what);
    const item: DetailItem = { environmentId: id(o.environmentId, "环境 ID"), name: varName(o.name) };
    if (o.vaultId !== undefined) item.vaultId = id(o.vaultId, "变量库 ID");
    return item;
  });
}

/** 解析 detail；只检查格式，权限由 checkDetail 检查。 */
function parseDetail(raw: string): Detail & { ephPub?: string } {
  let o: Record<string, unknown>;
  try {
    o = obj(JSON.parse(raw), "请求详情");
  } catch (e) {
    throw e instanceof SyntaxError ? bad("请求详情不是有效的 JSON。") : e;
  }
  if (o.kind !== "read" && o.kind !== "write") throw bad("请求类型只能是 read 或 write。");
  str(o.command ?? "", "命令", 1000);
  str(o.cwd ?? "", "目录", 1000);
  const items = parseItems(o.items, "变量列表");
  const del = parseItems(o.delete, "删除列表");
  const total = items.length + del.length;
  if (total < 1 || total > MAX_ITEMS) throw bad(`一次请求需要 1 到 ${MAX_ITEMS} 个变量。`);
  const detail: Detail & { ephPub?: string } = {
    kind: o.kind,
    deviceId: id(o.deviceId, "设备 ID"),
    createdAt: int(o.createdAt, "createdAt"),
    items,
    delete: del,
  };
  if (o.kind === "read") {
    if (del.length || items.some((i) => i.vaultId)) throw bad("读取请求只能列出要读取的变量。");
    detail.ephPub = bin(o.ephPub, "临时公钥", 32);
  }
  return detail;
}

/**
 * 按服务端数据检查请求：环境授权给了这台设备、没有到期、没有开启本机解密，名字在环境里；
 * 写入请求还要读写权限、可以修改的引用，新增变量要在可以新增的变量库里且名字不重复。
 */
function checkDetail(deps: Deps, d: Device, detail: Detail) {
  const envs = new Map(grantedEnvs(deps.sql, d, deps.now()).map((e) => [e.id, e]));
  const names = vaultNames(deps.sql);
  const env = (it: DetailItem): GrantedEnv => {
    const e = envs.get(it.environmentId);
    if (!e) throw forbidden("请求的环境没有授权给这台设备，或者授权已到期。");
    if (e.local_decrypt) throw bad(`环境“${e.name}”开启了本机解密，不需要手机批准。`);
    if (detail.kind === "write" && e.role !== "rw") throw forbidden(`这台设备对环境“${e.name}”只有只读权限。`);
    return e;
  };
  const itemIn = (e: GrantedEnv, name: string) => expand(e.refs, names).items.find((i) => i.name === name);
  for (const it of detail.items) {
    const e = env(it);
    const existing = itemIn(e, it.name);
    if (detail.kind === "read") {
      if (!existing) throw bad(`环境“${e.name}”里没有 ${it.name}。`);
      continue;
    }
    if (it.vaultId) {
      const creatable = e.refs.some((r) => r.vaultId === it.vaultId && r.scope === "all" && r.writable);
      if (!creatable || !one(deps.sql, `SELECT 1 FROM vaults WHERE id = ?`, it.vaultId)) {
        throw forbidden(`不能通过环境“${e.name}”在这个变量库里新增变量。`);
      }
      if (existing || names(it.vaultId).includes(it.name)) throw bad(`${it.name} 已经存在，请改为修改。`);
    } else if (!existing?.writable) {
      throw forbidden(`环境“${e.name}”里的 ${it.name} 不允许修改。`);
    }
  }
  for (const it of detail.delete) {
    const e = env(it);
    if (!itemIn(e, it.name)?.writable) throw forbidden(`环境“${e.name}”里的 ${it.name} 不允许删除。`);
  }
}

/** 写入请求的 payload：为每台管理设备各加密一份。 */
function checkPayload(raw: string) {
  let o: Record<string, unknown>;
  try {
    o = obj(JSON.parse(raw), "写入内容");
  } catch (e) {
    throw e instanceof SyntaxError ? bad("写入内容不是有效的 JSON。") : e;
  }
  const sealed = arr(o.sealed, "写入内容");
  if (!sealed.length) throw bad("写入内容需要加密给至少一台管理设备。");
  for (const s of sealed) {
    const x = obj(s, "写入内容");
    id(x.managerId, "管理设备 ID");
    bin(x.sealed, "写入内容", undefined, 2_000_000);
  }
}

function approvalView(a: Approval) {
  return { id: a.id, deviceId: a.device_id, detail: a.detail, payload: a.payload, sig: a.sig, createdAt: a.created_at, expiresAt: a.expires_at };
}

function authorizationView(x: Authorization) {
  return {
    id: x.id,
    deviceId: x.device_id,
    items: (JSON.parse(x.items) as AuthItem[]).map((i) => ({ environmentId: i.environmentId, name: i.name })),
    scope: x.scope,
    expiresAt: x.expires_at,
  };
}

/** 发起方离开：仍在等待的请求作废，通知管理设备刷新。 */
export function approvalLeft(deps: Deps, approvalId: string) {
  const a = approvalById(deps, approvalId);
  if (a?.status !== "pending") return;
  deps.sql.run(`UPDATE approvals SET status = 'cancelled' WHERE id = ?`, approvalId);
  deps.notifier.send("managers", { type: "approval" });
}

/** 处理后发给发起方的消息。 */
function resultMessage(a: Approval): { type: string; [k: string]: unknown } | undefined {
  if (a.status === "approved") return { type: "approved", result: a.result ? JSON.parse(a.result) : {} };
  if (a.status === "rejected" || a.status === "expired") return { type: a.status };
  return undefined;
}

/** 定期检查批准请求的等待连接：心跳超时的作废，已处理的把结果发给发起方并断开。 */
export function checkApprovalWaiters(deps: Deps, list: { key: string; seenAt: number }[]) {
  const now = deps.now();
  let changed = false;
  if (deps.sql.all(`SELECT 1 FROM approvals WHERE status = 'pending' AND expires_at <= ? LIMIT 1`, now).length) {
    deps.sql.run(`UPDATE approvals SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?`, now);
    changed = true;
  }
  deps.sql.run(`DELETE FROM approvals WHERE expires_at <= ?`, now - RESULT_TTL);
  for (const w of list) {
    const approvalId = w.key.slice(APPROVAL_KEY.length);
    const a = approvalById(deps, approvalId);
    if (a?.status === "pending") {
      if (w.seenAt >= now - WAITER_TIMEOUT) continue;
      deps.waiters.close(w.key);
      approvalLeft(deps, approvalId);
      continue;
    }
    deps.waiters.close(w.key, a ? resultMessage(a) : undefined);
  }
  if (changed) deps.notifier.send("managers", { type: "approval" });
}

/** 结束一项正在生效的授权，通知那台设备的保管进程。 */
function endAuthorization(deps: Deps, x: Authorization) {
  deps.sql.run(`DELETE FROM authorizations WHERE id = ?`, x.id);
  deps.notifier.send({ device: x.device_id }, { type: "authorization-ended", id: x.id });
}

/**
 * 结束不再成立的授权：到期、设备被撤销、环境的授权被删除或到期或改为本机解密、环境的引用改变、
 * 授权里的变量被修改或删除。在每个修改数据的请求之后调用。
 */
export function pruneAuthorizations(deps: Deps) {
  const { sql } = deps;
  const rows = sql.all<Authorization>(`SELECT * FROM authorizations`);
  if (!rows.length) return;
  const now = deps.now();
  const refs = new Map(sql.all<{ id: string; refs: string }>(`SELECT id, refs FROM environments`).map((e) => [e.id, e.refs]));
  for (const x of rows) {
    const d = one<Device>(sql, `SELECT * FROM devices WHERE id = ?`, x.device_id);
    const ok = (() => {
      if (!d || d.status !== "active") return false;
      if (x.expires_at !== 0 && x.expires_at <= now) return false;
      const grants = new Map(grantedEnvs(sql, d, now).map((e) => [e.id, e]));
      const snapshot = JSON.parse(x.env_refs) as Record<string, string>;
      for (const [envId, stored] of Object.entries(snapshot)) {
        if (refs.get(envId) !== stored) return false;
        const g = grants.get(envId);
        if (!g || g.local_decrypt) return false;
      }
      for (const it of JSON.parse(x.items) as AuthItem[]) {
        const v = one<{ seq: number; deleted: number }>(
          sql,
          `SELECT seq, deleted FROM variables WHERE vault_id = ? AND name = ?`,
          it.vaultId,
          it.source,
        );
        if (!v || v.deleted || v.seq !== it.seq) return false;
      }
      return true;
    })();
    if (!ok) endAuthorization(deps, x);
  }
}

export function approvalRoutes(app: Hono, deps: Deps) {
  const { sql } = deps;

  /** 管理设备要处理的请求：必须仍待处理，且发起方还在等待。 */
  const pendingApproval = (approvalId: string): Approval => {
    checkApprovalWaiters(deps, []);
    const a = approvalById(deps, approvalId);
    if (!a) throw notFound("批准请求不存在或已过期。");
    if (a.status !== "pending") throw conflict("这个请求已经处理过或已过期。");
    if (!waiting(deps, a.id)) throw conflict("电脑上已经不再等待，这次请求已失效。");
    return a;
  };

  const ownApproval = (d: Device, approvalId: string): Approval => {
    const a = approvalById(deps, approvalId);
    if (!a || a.device_id !== d.id) throw notFound("批准请求不存在或已过期。");
    return a;
  };

  app.post("/api/v1/approvals", async (c) => {
    const d = await requireDevice(c, deps);
    if (d.kind === "manager") throw forbidden("管理设备可以直接解密，不需要批准。");
    const body = await readJson(c);
    const approvalId = id(body.id, "请求 ID");
    const detailRaw = str(body.detail, "请求详情", 64 * 1024);
    const detail = parseDetail(detailRaw);
    const payload = body.payload === undefined ? "" : str(body.payload, "写入内容", 2_100_000);
    const sig = bin(body.sig, "签名", 64);
    if (!(await verifyEd25519(d.sign_pub, await approvalRequestMsg(approvalId, d.id, detailRaw, payload), sig))) {
      throw bad("请求的签名不对。");
    }
    if (detail.deviceId !== d.id) throw bad("请求里的设备不是当前设备。");
    const now = deps.now();
    if (Math.abs(detail.createdAt - now) > CLOCK_SKEW) throw bad("这台电脑的时间与服务器相差太多，请校准系统时间后重试。");
    if (detail.kind === "read" ? payload !== "" : payload === "") throw bad("只有写入请求带写入内容。");
    if (detail.kind === "write") checkPayload(payload);
    checkDetail(deps, d, detail);
    checkApprovalWaiters(deps, []);
    if (approvalById(deps, approvalId)) throw conflict("这个请求 ID 已经用过。");
    const pending = sql.all(`SELECT 1 FROM approvals WHERE device_id = ? AND status = 'pending'`, d.id).length;
    if (pending >= MAX_PENDING) throw conflict("这台电脑等待批准的请求太多，请先在手机上处理，或结束等待后重试。");
    const expiresAt = now + APPROVAL_TTL;
    sql.run(
      `INSERT INTO approvals (id, device_id, kind, detail, payload, sig, status, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
      approvalId,
      d.id,
      detail.kind,
      detailRaw,
      payload,
      sig,
      now,
      expiresAt,
    );
    return c.json({ expiresAt });
  });

  app.get("/api/v1/approvals/:id/events", async (c) => {
    const d = await requireDevice(c, deps);
    const a = ownApproval(d, c.req.param("id"));
    if (c.req.header("upgrade")?.toLowerCase() !== "websocket") throw bad("需要 WebSocket 连接。");
    if (a.status !== "pending") throw conflict("这个请求已经处理过或已过期。");
    if (waiting(deps, a.id)) throw conflict("这个请求已经在另一处等待批准。");
    const res = deps.waiters.accept(APPROVAL_KEY + a.id);
    deps.notifier.send("managers", { type: "approval" });
    notifyInBackground(deps, "approval");
    return res;
  });

  app.get("/api/v1/approvals/:id/status", async (c) => {
    const d = await requireDevice(c, deps);
    checkApprovalWaiters(deps, []);
    const a = ownApproval(d, c.req.param("id"));
    const msg = resultMessage(a);
    return c.json({ status: a.status, ...(msg?.result ? { result: msg.result } : {}) });
  });

  app.get("/api/v1/approvals", async (c) => {
    await requireDevice(c, deps, { manager: true });
    checkApprovalWaiters(deps, []);
    const rows = sql.all<Approval>(`SELECT * FROM approvals WHERE status = 'pending' ORDER BY created_at`);
    return c.json({ approvals: rows.filter((a) => waiting(deps, a.id)).map(approvalView) });
  });

  app.post("/api/v1/approvals/:id/approve", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = pendingApproval(c.req.param("id"));
    const body = await readJson(c);
    let result: Record<string, unknown> = {};
    if (a.kind === "read") {
      const sealed = bin(body.sealed, "批准结果", undefined, 2_000_000);
      const sig = bin(body.sig, "签名", 64);
      const scope = body.scope as Scope;
      if (!SCOPES.includes(scope)) throw bad("授权范围只能是 once、terminal 或 all。");
      const expiresAt = scope === "once" ? 0 : int(body.expiresAt, "到期时间");
      const rootPub = one<{ root_pub: string }>(sql, `SELECT root_pub FROM account WHERE id = 1`)!.root_pub;
      if (!(await verifyEd25519(rootPub, await approvalGrantMsg(a.id, sealed), sig))) throw bad("批准结果的签名不对。");
      result = { sealed, sig };
      if (scope !== "once") recordAuthorization(deps, a, scope, expiresAt);
    }
    sql.run(`UPDATE approvals SET status = 'approved', result = ? WHERE id = ?`, JSON.stringify(result), a.id);
    deps.waiters.close(APPROVAL_KEY + a.id, { type: "approved", result });
    deps.notifier.send("managers", { type: "approval" });
    return c.json({});
  });

  app.post("/api/v1/approvals/:id/reject", async (c) => {
    await requireDevice(c, deps, { manager: true });
    const a = pendingApproval(c.req.param("id"));
    sql.run(`UPDATE approvals SET status = 'rejected' WHERE id = ?`, a.id);
    deps.waiters.close(APPROVAL_KEY + a.id, { type: "rejected" });
    deps.notifier.send("managers", { type: "approval" });
    return c.json({});
  });

  app.get("/api/v1/authorizations", async (c) => {
    const d = await requireDevice(c, deps);
    pruneAuthorizations(deps);
    const rows =
      d.kind === "manager"
        ? sql.all<Authorization>(`SELECT * FROM authorizations ORDER BY created_at`)
        : sql.all<Authorization>(`SELECT * FROM authorizations WHERE device_id = ? ORDER BY created_at`, d.id);
    return c.json({ authorizations: rows.map(authorizationView) });
  });

  app.post("/api/v1/authorizations/:id/end", async (c) => {
    const d = await requireDevice(c, deps);
    const x = one<Authorization>(sql, `SELECT * FROM authorizations WHERE id = ?`, c.req.param("id"));
    if (x && (d.kind === "manager" || x.device_id === d.id)) endAuthorization(deps, x);
    return c.json({});
  });
}

/** 每个修改数据的请求之后，结束不再成立的授权（授权、环境、设备、变量的变化都会影响）。注册在全部路由之前。 */
export function authorizationGuard(app: Hono, deps: Deps) {
  app.use(async (c, next) => {
    await next();
    if (c.req.method !== "GET") pruneAuthorizations(deps);
  });
}

/** 读取请求批准时记录授权：环境里的名字、所在变量库和原名、当时的版本，以及各环境的引用。 */
function recordAuthorization(deps: Deps, a: Approval, scope: Scope, expiresAt: number) {
  const { sql } = deps;
  const d = one<Device>(sql, `SELECT * FROM devices WHERE id = ?`, a.device_id)!;
  const detail = JSON.parse(a.detail) as Detail;
  const envs = new Map(grantedEnvs(sql, d, deps.now()).map((e) => [e.id, e]));
  const names = vaultNames(sql);
  const items: AuthItem[] = [];
  const envRefs: Record<string, string> = {};
  for (const it of detail.items) {
    const e = envs.get(it.environmentId);
    const found = e && expand(e.refs, names).items.find((i) => i.name === it.name);
    if (!e || !found) throw conflict("请求的环境在这期间有变化，请让电脑重新发起。");
    const v = one<{ seq: number }>(sql, `SELECT seq FROM variables WHERE vault_id = ? AND name = ?`, found.vaultId, found.source);
    items.push({ environmentId: e.id, name: it.name, vaultId: found.vaultId, source: found.source, seq: v?.seq ?? 0 });
    envRefs[e.id] = one<{ refs: string }>(sql, `SELECT refs FROM environments WHERE id = ?`, e.id)!.refs;
  }
  sql.run(
    `INSERT OR REPLACE INTO authorizations (id, device_id, items, env_refs, scope, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    a.id,
    a.device_id,
    JSON.stringify(items),
    JSON.stringify(envRefs),
    scope,
    expiresAt,
    deps.now(),
  );
}

