// 编码、错误响应与输入校验。
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    /** 附加在错误响应中的字段，例如 retryAfter（秒）。 */
    readonly extra: Record<string, string | number> = {},
  ) {
    super(message);
  }
}

/** 被限流：retryAfter 为建议等待的秒数，同时写入 Retry-After 响应头。 */
export const rateLimited = (message: string, retryAfterMs: number) =>
  new ApiError(429, "rate_limited", message, { retryAfter: Math.max(1, Math.ceil(retryAfterMs / 1000)) });
export const bad = (message: string) => new ApiError(400, "invalid_request", message);
export const notFound = (message: string) => new ApiError(404, "not_found", message);

export function errorResponse(e: unknown): Response {
  if (e instanceof ApiError) {
    const headers: Record<string, string> = e.extra.retryAfter ? { "retry-after": String(e.extra.retryAfter) } : {};
    return Response.json({ error: e.code, message: e.message, ...e.extra }, { status: e.status, headers });
  }
  console.error(e);
  return Response.json({ error: "internal", message: "推送服务暂时不可用，请稍后再试。" }, { status: 500 });
}

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export const utf8 = (s: string) => new TextEncoder().encode(s);

export async function sha256(data: string): Promise<string> {
  return b64(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(data))));
}

export const randomB64 = (n: number) => b64(crypto.getRandomValues(new Uint8Array(n)));

/** 句柄：32 字节随机数的 b64，43 个字符（docs/protocol.md 3.10）。 */
export const HANDLE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function obj(v: unknown): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw bad("请求内容格式不对。");
  return v as Record<string, unknown>;
}
