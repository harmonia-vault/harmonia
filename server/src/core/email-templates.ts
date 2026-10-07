// 验证码邮件模板（沿用旧项目版式）。

export type CodeEmailPurpose = "verification" | "password" | "reset";
export interface Email { to: string; subject: string; text: string; html?: string }
export interface CodeEmailInput { purpose: CodeEmailPurpose; email: string; code: string; minutes: number }

const sans = "-apple-system,BlinkMacSystemFont,'PingFang SC','Hiragino Sans GB','Microsoft YaHei','Segoe UI',sans-serif";
const serif = "'Songti SC','Noto Serif SC',SimSun,Georgia,serif";
const mono = "Menlo,Consolas,'SF Mono','Courier New',monospace";
// 验证与重置共用版式，只换主色与文案；正文不含验证码之外的任何凭据。
// 分组横条是无内容的装饰元素，复制验证码时不会带入任何分隔字符。
const copy = {
  verification: {
    subject: "Harmonia 邮箱验证码", title: "验证您的邮箱", label: "邮箱验证",
    lead: "感谢注册 Harmonia。请在 App 中输入以下验证码，完成邮箱验证。",
    preheader: "请在 App 中输入验证码，完成邮箱验证。",
    ignore: "如果您没有注册 Harmonia，请忽略此邮件。",
    accent: "#1C1917", bar: "#FAFAF9", barMuted: "#D6D3D1", dash: "#D6D3D1",
  },
  password: {
    subject: "Harmonia 找回密码验证码", title: "重设登录密码", label: "找回密码",
    lead: "我们收到了重设您 Harmonia 登录密码的请求。请在 App 中输入以下验证码，然后设置新密码。保险库中的数据不受影响。",
    preheader: "请在 App 中输入验证码，然后设置新密码。",
    ignore: "如果这不是您本人的操作，请忽略此邮件，您的密码不会改变。",
    accent: "#1C1917", bar: "#FAFAF9", barMuted: "#D6D3D1", dash: "#D6D3D1",
  },
  reset: {
    subject: "Harmonia 账号重置验证码", title: "重置您的账号", label: "账号重置",
    lead: "我们收到了重置您 Harmonia 账号的请求。如确认是您本人操作，请在 App 中输入以下验证码继续。",
    preheader: "如确认是您本人操作，请在 App 中输入验证码继续。",
    ignore: "如果这不是您本人的操作，请忽略此邮件，您的账号不会受到影响。",
    accent: "#B3261E", bar: "#FFFFFF", barMuted: "#F7DAD3", dash: "#EBC8C0",
  },
} as const;
const warning = { title: "重置后数据无法找回", body: "保险库中的全部数据、已授权的设备和恢复设置都将被永久删除。" };
const caution = "为保障账号安全，请勿将验证码透露给他人。";
const footer = "此邮件由 Harmonia 服务自动发送，请勿直接回复。";

/** 邮件验证码：8 个 Crockford Base32 字符（不含 I、L、O、U）。 */
export const CODE_PATTERN = /^[0-9A-HJKMNP-TV-Z]{8}$/;

function escape(value: string): string {
  return value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export function codeEmail(input: CodeEmailInput): Omit<Email, "to"> {
  const c = copy[input.purpose];
  if (!c || !CODE_PATTERN.test(input.code) || !Number.isSafeInteger(input.minutes) || input.minutes < 1) throw new Error("email_template_input_invalid");
  const head = input.code.slice(0, 4), tail = input.code.slice(4), validity = `${input.minutes} 分钟内有效 · 仅可使用一次`;
  const text = [
    c.title, "", c.lead, "", `用途：${c.label}`, `账号：${input.email}`,
    ...(input.purpose === "reset" ? ["", `${warning.title}：${warning.body}`] : []),
    "", `验证码：${input.code}`, `${input.minutes} 分钟内有效，仅可使用一次，字母不区分大小写。`,
    "", c.ignore, caution, "", footer,
  ].join("\n");
  const row = (key: string, value: string): string =>
    `<tr><td width="76" style="padding:7px 0;border-bottom:1px solid #E7E5E4;color:#78716C;">${key}</td><td style="padding:7px 0;border-bottom:1px solid #E7E5E4;color:#1C1917;word-break:break-all;">${value}</td></tr>`;
  const alert = input.purpose !== "reset" ? "" :
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 24px;"><tr><td style="border:1px solid #B3261E;background:#FDF3F1;padding:12px 14px;font-family:${sans};color:#5C140E;">
<div style="font-size:13px;font-weight:600;margin:0 0 4px;">${warning.title}</div><div style="font-size:13px;line-height:1.7;">${warning.body}</div></td></tr></table>`;
  const html = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light"><title>${c.subject}</title>
<style>@media (max-width:420px){.hm-body{padding-left:20px!important;padding-right:20px!important}.hm-code{font-size:28px!important;letter-spacing:4px!important;padding-left:4px!important}.hm-dash{margin-right:8px!important}}</style></head>
<body style="margin:0;padding:0;background:#F5F5F4;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${c.preheader}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F5F5F4;"><tr><td align="center" style="padding:32px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:500px;background:#FFFFFF;border:1px solid #D6D3D1;">
<tr><td style="height:4px;line-height:4px;font-size:0;background:${c.accent};">&nbsp;</td></tr>
<tr><td class="hm-body" style="padding:28px 32px 24px;font-family:${sans};color:#1C1917;">
<div style="font-family:${mono};font-size:11px;letter-spacing:2px;color:#78716C;">Harmonia · 安全通知</div>
<div style="font-family:${serif};font-size:26px;font-weight:500;line-height:1.3;color:#1C1917;margin:18px 0 0;padding:0 0 14px;border-bottom:2px solid #1C1917;">${c.title}</div>
<div style="font-size:14px;line-height:1.8;color:#44403C;margin:16px 0 18px;">${c.lead}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="font-family:${sans};font-size:13px;line-height:1.5;margin:0 0 ${alert ? 18 : 24}px;">${row("用途", c.label)}${row("账号", escape(input.email))}</table>
${alert}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1.5px solid ${c.accent};">
<tr><td style="background:${c.accent};padding:7px 14px;font-family:${sans};font-size:12px;color:${c.bar};">验证码</td><td align="right" style="background:${c.accent};padding:7px 14px;font-family:${sans};font-size:12px;color:${c.barMuted};">${validity}</td></tr>
<tr><td colspan="2" align="center" class="hm-code" style="padding:20px 0 18px 6px;font-family:${mono};font-size:34px;font-weight:500;letter-spacing:6px;color:#1C1917;white-space:nowrap;">${head}<span class="hm-dash" style="display:inline-block;width:10px;height:3px;line-height:0;background:#1C1917;vertical-align:0.32em;margin:0 10px 0 4px;"></span>${tail}</td></tr>
<tr><td colspan="2" style="padding:0 14px;"><div style="border-top:1px dashed ${c.dash};padding:8px 0 10px;text-align:center;font-family:${sans};font-size:11px;color:#78716C;">字母不区分大小写</div></td></tr>
</table>
<div style="font-size:12px;line-height:1.8;color:#78716C;margin:22px 0 0;">${c.ignore}<br>${caution}</div>
</td></tr>
<tr><td class="hm-body" style="border-top:1px solid #E7E5E4;padding:12px 32px;font-family:${sans};font-size:11px;color:#A8A29E;">${footer}</td></tr>
</table></td></tr></table></body></html>`;
  return { subject: c.subject, text, html };
}
