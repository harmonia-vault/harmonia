// 邮件验证码：生成、发送与校验（docs/protocol.md 3.0）。
import { one } from "./db";
import type { Deps } from "./context";
import { CODE_PATTERN, codeEmail, type CodeEmailPurpose, type Email } from "./email-templates";
import { ApiError, b64, bad, sha256, utf8 } from "./util";

export interface Mailer {
  /** 未配置发信时为 false。 */
  readonly available: boolean;
  send(message: Email, meta: { purpose: CodeEmailPurpose; code: string }): Promise<void>;
}

const CODE_TTL = 15 * 60_000;
const RESEND_INTERVAL = 60_000;
const MAX_ATTEMPTS = 5;
/** Crockford Base32 字母表：不含 I、L、O、U，避免手抄时混淆。 */
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const hashCode = async (purpose: string, code: string) => b64(await sha256(utf8(`${purpose}:${code}`)));

export function normalizeCode(input: unknown): string {
  if (typeof input !== "string") throw bad("请输入邮件中的 8 位验证码。");
  const s = input.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (!CODE_PATTERN.test(s)) throw bad("请输入邮件中的 8 位验证码。");
  return s;
}

/** 生成并发送验证码。force=false 时遵守 60 秒重发间隔。 */
export async function sendCode(deps: Deps, email: string, purpose: CodeEmailPurpose): Promise<void> {
  if (!deps.mailer.available) {
    throw new ApiError(503, "email_unavailable", "服务器没有配置发信，暂时无法发送验证码。请联系服务器管理员。");
  }
  const now = deps.now();
  const prev = one<{ sent_at: number }>(deps.sql, `SELECT sent_at FROM email_codes WHERE purpose = ?`, purpose);
  if (prev && now - prev.sent_at < RESEND_INTERVAL) {
    const wait = Math.ceil((RESEND_INTERVAL - (now - prev.sent_at)) / 1000);
    throw new ApiError(429, "rate_limited", `验证码已发送，请 ${wait} 秒后再试。`);
  }
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const code = Array.from(bytes, (b) => ALPHABET[b % 32]).join("");
  deps.sql.run(
    `INSERT OR REPLACE INTO email_codes (purpose, code_hash, expires_at, attempts, sent_at) VALUES (?, ?, ?, 0, ?)`,
    purpose,
    await hashCode(purpose, code),
    now + CODE_TTL,
    now,
  );
  await deps.mailer.send({ to: email, ...codeEmail({ purpose, email, code, minutes: CODE_TTL / 60_000 }) }, { purpose, code });
}

/** 校验验证码；成功后作废，失败计数。 */
export async function checkCode(deps: Deps, purpose: CodeEmailPurpose, input: unknown): Promise<void> {
  const code = normalizeCode(input);
  const row = one<{ code_hash: string; expires_at: number; attempts: number }>(
    deps.sql,
    `SELECT * FROM email_codes WHERE purpose = ?`,
    purpose,
  );
  if (!row || row.expires_at <= deps.now() || row.attempts >= MAX_ATTEMPTS) {
    throw bad("验证码已失效，请重新获取。");
  }
  if (row.code_hash !== (await hashCode(purpose, code))) {
    deps.sql.run(`UPDATE email_codes SET attempts = attempts + 1 WHERE purpose = ?`, purpose);
    const left = MAX_ATTEMPTS - row.attempts - 1;
    throw bad(left > 0 ? `验证码不对，还可以再试 ${left} 次。` : "验证码已失效，请重新获取。");
  }
  deps.sql.run(`DELETE FROM email_codes WHERE purpose = ?`, purpose);
}
