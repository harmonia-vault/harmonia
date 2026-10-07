// 编码、密码学校验与输入校验（docs/protocol.md 第 1、2 节）。

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    /** 附加在错误响应中的字段，例如 retryAfter（秒）或 flow。 */
    readonly extra: Record<string, string | number> = {},
  ) {
    super(message);
  }
}

/** 被限流：retryAfter 为建议等待的秒数，同时写入 Retry-After 响应头。 */
export const rateLimited = (message: string, retryAfterMs: number, code = "rate_limited") =>
  new ApiError(429, code, message, { retryAfter: Math.max(1, Math.ceil(retryAfterMs / 1000)) });

export const bad = (message: string) => new ApiError(400, "invalid_request", message);
export const unauthorized = (message = "登录已失效，请重新登录。") => new ApiError(401, "unauthorized", message);
export const forbidden = (message = "没有权限执行此操作。") => new ApiError(403, "forbidden", message);
export const notFound = (message = "要操作的内容不存在。") => new ApiError(404, "not_found", message);
export const conflict = (message: string) => new ApiError(409, "conflict", message);

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw bad("编码格式不对。");
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export const utf8 = (s: string) => new TextEncoder().encode(s);

/** 规范数组：字符串数组的紧凑 JSON。 */
export const canonical = (...items: string[]) => utf8(JSON.stringify(items));

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? utf8(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export const randomB64 = (n: number) => b64(crypto.getRandomValues(new Uint8Array(n)));
export const newId = () => randomB64(16);

export async function verifyEd25519(pubB64: string, msg: Uint8Array, sigB64: string): Promise<boolean> {
  try {
    const pub = unb64(pubB64);
    const sig = unb64(sigB64);
    if (pub.length !== 32 || sig.length !== 64) return false;
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, sig, msg);
  } catch {
    return false;
  }
}

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---- 签名原文 ----

export const deviceCertMsg = (id: string, kind: string, signPub: string, boxPub: string) =>
  canonical("harmonia.device", id, kind, signPub, boxPub);

export const envelopeMsg = async (envId: string, keyVersion: number, recipient: string, sealedB64: string) =>
  canonical("harmonia.envelope", envId, String(keyVersion), recipient, b64(await sha256(unb64(sealedB64))));

export const rootRecoveryMsg = async (generation: number, sealedB64: string) =>
  canonical("harmonia.root-recovery", String(generation), b64(await sha256(unb64(sealedB64))));

export const authMsg = (deviceId: string, nonce: string) => canonical("harmonia.auth", deviceId, nonce);
export const recoveryAuthMsg = (nonce: string) => canonical("harmonia.recovery-auth", nonce);

// ---- 输入校验 ----

type Json = Record<string, unknown>;

export function obj(v: unknown, what = "请求内容"): Json {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw bad(`${what}格式不对。`);
  return v as Json;
}

export function arr(v: unknown, what: string): unknown[] {
  if (!Array.isArray(v)) throw bad(`${what}格式不对。`);
  if (v.length > 1000) throw bad(`${what}数量过多。`);
  return v;
}

export function str(v: unknown, what: string, max = 1024): string {
  if (typeof v !== "string" || v.length > max) throw bad(`${what}格式不对。`);
  return v;
}

export function id(v: unknown, what = "ID"): string {
  const s = str(v, what);
  if (!/^[A-Za-z0-9_-]{22}$/.test(s)) throw bad(`${what}格式不对。`);
  return s;
}

/** 固定长度二进制字段（b64）。 */
export function bin(v: unknown, what: string, len?: number, max = 200_000): string {
  const s = str(v, what, max);
  const bytes = unb64(s);
  if (len !== undefined && bytes.length !== len) throw bad(`${what}长度不对。`);
  if (b64(bytes) !== s) throw bad(`${what}编码不规范。`);
  return s;
}

export function label(v: unknown, what: string): string {
  const s = str(v, what, 256).trim();
  if (s.length < 1 || [...s].length > 64) throw bad(`${what}需要 1 到 64 个字符。`);
  return s;
}

export function varName(v: unknown): string {
  const s = str(v, "变量名", 128);
  if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(s)) throw bad("变量名只能包含字母、数字和下划线，且不能以数字开头。");
  if (s.toUpperCase().startsWith("__HARMONIA_")) throw bad("以 __HARMONIA_ 开头的变量名为保留名称。");
  return s;
}

export function int(v: unknown, what: string, min = 0): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < min) throw bad(`${what}格式不对。`);
  return v;
}

/** 十进制字符串形式的正整数（keyVersion、generation）。 */
export function decimal(v: unknown, what: string): number {
  const s = str(v, what, 16);
  if (!/^[1-9][0-9]{0,14}$/.test(s)) throw bad(`${what}格式不对。`);
  return Number(s);
}

export const ROLES = ["ro", "rw", "admin"] as const;
export type Role = (typeof ROLES)[number];

export function role(v: unknown): Role {
  if (!ROLES.includes(v as Role)) throw bad("权限只能是只读、读写或管理。");
  return v as Role;
}
