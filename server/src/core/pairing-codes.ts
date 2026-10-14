// 一次性配对码（docs/protocol.md 3.2、3.8）：管理设备生成，发起方带上它，配对请求才会出现在管理设备上。
// 它只代替原来的密码，不代替指纹核对。服务端只保存哈希；每个配对码在过期前或用掉之前一直有效，
// 每个账号同时最多 MAX_PAIRING_CODES 个，超出时作废最早生成的那个。
import { one } from "./db";
import type { Deps } from "./context";
import { checkWait, recordFailure } from "./guard";
import { b64, bad, parseCode, randomCode, sha256, unauthorized } from "./util";

export const DEFAULT_PAIRING_MINUTES = 10;
export const MAX_PAIRING_CODES = 10;

const codeHash = async (code: string) => b64(await sha256(`pairing:${code}`));

/** 生成新的配对码，有效期 [minutes] 分钟（5 到 60，省略时 10）；已有的配对码不受影响。 */
export async function createPairingCode(deps: Deps, minutes: unknown): Promise<{ code: string; expiresAt: number }> {
  const m = minutes ?? DEFAULT_PAIRING_MINUTES;
  if (typeof m !== "number" || !Number.isInteger(m) || m < 5 || m > 60) {
    throw bad("配对码的有效期要在 5 到 60 分钟之间。");
  }
  const code = randomCode();
  const hash = await codeHash(code);
  const now = deps.now();
  const expiresAt = now + m * 60_000;
  deps.sql.transaction(() => {
    deps.sql.run(`DELETE FROM pairing_codes WHERE expires_at <= ?`, now);
    deps.sql.run(`INSERT OR REPLACE INTO pairing_codes (code_hash, created_at, expires_at) VALUES (?, ?, ?)`, hash, now, expiresAt);
    deps.sql.run(
      `DELETE FROM pairing_codes WHERE rowid NOT IN (SELECT rowid FROM pairing_codes ORDER BY created_at DESC, rowid DESC LIMIT ?)`,
      MAX_PAIRING_CODES,
    );
  });
  return { code, expiresAt };
}

/**
 * 校验发起方给出的配对码，返回它的哈希；之后在创建请求的同一个事务里调用 consumePairingCode 作废它。
 * 这个网络在等待期内时不校验；输错时计入该网络的递增等待。
 */
export async function checkPairingCode(deps: Deps, net: string, input: unknown): Promise<string> {
  checkWait(deps, net);
  const code = parseCode(input);
  const hash = code ? await codeHash(code) : "";
  const row = code
    ? one<{ expires_at: number }>(deps.sql, `SELECT expires_at FROM pairing_codes WHERE code_hash = ?`, hash)
    : undefined;
  if (!row || row.expires_at <= deps.now()) {
    recordFailure(deps, net);
    throw unauthorized("配对码不对或已过期。请在管理设备的“设备 → 添加设备”中重新生成，或者不填配对码，改用扫码。");
  }
  return hash;
}

/** 在创建请求的事务里作废配对码；配对码已被别的请求用掉或已失效时抛错，整个事务回滚。 */
export function consumePairingCode(deps: Deps, hash: string) {
  if (!one(deps.sql, `SELECT 1 FROM pairing_codes WHERE code_hash = ?`, hash)) {
    throw unauthorized("配对码已经用过或已失效，请在管理设备上重新生成。");
  }
  deps.sql.run(`DELETE FROM pairing_codes WHERE code_hash = ?`, hash);
}
