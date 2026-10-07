// 邮件验证码：生成、发送与校验，以及发信额度（docs/protocol.md 3.0、3.8）。
import { one } from "./db";
import type { Deps } from "./context";
import { CODE_PATTERN, codeEmail, type CodeEmailPurpose, type Email } from "./email-templates";
import { ApiError, b64, bad, randomB64, rateLimited, sha256, utf8 } from "./util";

export interface Mailer {
  /** 未配置发信时为 false。 */
  readonly available: boolean;
  send(message: Email, meta: { purpose: CodeEmailPurpose; code: string }): Promise<void>;
}

const CODE_TTL = 15 * 60_000;
const RESEND_INTERVAL = 60_000;
const MAX_ATTEMPTS = 5;
const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;
/** Crockford Base32 字母表：不含 I、L、O、U，避免手抄时混淆。 */
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/**
 * 发信额度，按 1 小时（或 1 天）滚动。登录验证码只在密码正确后发送，单独计算，
 * 不会被不知道密码的人耗尽；其他用途按网络和合计两级限制。
 */
const LIMITS = {
  login: [{ window: HOUR, max: 10, perNetwork: false }],
  other: [
    { window: HOUR, max: 2, perNetwork: true },
    { window: HOUR, max: 6, perNetwork: false },
    { window: DAY, max: 20, perNetwork: false },
  ],
} as const;

const hash = async (s: string) => b64(await sha256(utf8(s)));

export function normalizeCode(input: unknown): string {
  if (typeof input !== "string") throw bad("请输入邮件中的 8 位验证码。");
  const s = input.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (!CODE_PATTERN.test(s)) throw bad("请输入邮件中的 8 位验证码。");
  return s;
}

/** 检查发信额度；超出时抛出带建议等待时间的 rate_limited。 */
function checkBudget(deps: Deps, purpose: CodeEmailPurpose, net: string) {
  const now = deps.now();
  const last = one<{ at: number }>(deps.sql, `SELECT MAX(at) AS at FROM mail_log WHERE net = ?`, net)?.at;
  if (last && now - last < RESEND_INTERVAL) {
    const wait = RESEND_INTERVAL - (now - last);
    throw rateLimited(`验证码已发送，请 ${Math.ceil(wait / 1000)} 秒后再试。`, wait);
  }
  const kind = purpose === "login" ? "login" : "other";
  for (const l of LIMITS[kind]) {
    const rows = deps.sql.all<{ at: number }>(
      `SELECT at FROM mail_log WHERE kind = ? AND at > ? ${l.perNetwork ? "AND net = ?" : ""} ORDER BY at`,
      kind,
      now - l.window,
      ...(l.perNetwork ? [net] : []),
    );
    if (rows.length >= l.max) {
      throw rateLimited(
        "验证码发送次数过多，请稍后再试；已经收到的验证码 15 分钟内仍然有效。",
        rows[rows.length - l.max]!.at + l.window - now,
      );
    }
  }
}

/** 生成并发送验证码，返回绑定它的流程凭证 flow。同一网络、同一用途只保留最新一个。 */
export async function sendCode(deps: Deps, email: string, purpose: CodeEmailPurpose, net: string): Promise<string> {
  if (!deps.mailer.available) {
    throw new ApiError(503, "email_unavailable", "服务器没有配置发信，暂时无法发送验证码。请联系服务器管理员。");
  }
  checkBudget(deps, purpose, net);
  const now = deps.now();
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const code = Array.from(bytes, (b) => ALPHABET[b % 32]).join("");
  const flow = randomB64(32);
  const flowHash = await hash(flow);
  const codeHash = await hash(`${purpose}:${code}`);
  deps.sql.transaction(() => {
    deps.sql.run(`DELETE FROM email_flows WHERE purpose = ? AND net = ?`, purpose, net);
    deps.sql.run(
      `INSERT INTO email_flows (flow_hash, purpose, net, code_hash, expires_at, attempts) VALUES (?, ?, ?, ?, ?, 0)`,
      flowHash,
      purpose,
      net,
      codeHash,
      now + CODE_TTL,
    );
    deps.sql.run(`INSERT INTO mail_log (at, net, kind) VALUES (?, ?, ?)`, now, net, purpose === "login" ? "login" : "other");
  });
  await deps.mailer.send({ to: email, ...codeEmail({ purpose, email, code, minutes: CODE_TTL / 60_000 }) }, { purpose, code });
  return flow;
}

/** 校验某个流程凭证上的验证码；成功后作废，失败只计入这个流程。 */
export async function checkCode(deps: Deps, purpose: CodeEmailPurpose, flow: unknown, input: unknown): Promise<void> {
  const code = normalizeCode(input);
  const flowHash = typeof flow === "string" && flow ? await hash(flow) : "";
  const row = one<{ code_hash: string; expires_at: number; attempts: number }>(
    deps.sql,
    `SELECT * FROM email_flows WHERE flow_hash = ? AND purpose = ?`,
    flowHash,
    purpose,
  );
  if (!row || row.expires_at <= deps.now() || row.attempts >= MAX_ATTEMPTS) {
    throw bad("验证码已失效，请重新获取。");
  }
  if (row.code_hash !== (await hash(`${purpose}:${code}`))) {
    deps.sql.run(`UPDATE email_flows SET attempts = attempts + 1 WHERE flow_hash = ?`, flowHash);
    const left = MAX_ATTEMPTS - row.attempts - 1;
    throw bad(left > 0 ? `验证码不对，还可以再试 ${left} 次。` : "验证码已失效，请重新获取。");
  }
  deps.sql.run(`DELETE FROM email_flows WHERE flow_hash = ?`, flowHash);
}
