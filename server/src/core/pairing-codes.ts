// 一次性配对码（docs/protocol.md 3.2、3.8）：管理设备生成，发起方带上它，配对请求才会出现在管理设备上。
// 它只代替原来的密码，不代替指纹核对。服务端只保存哈希；每个账号同时只有一个，用一次即作废。
import { one } from "./db";
import type { Deps } from "./context";
import { checkWait, recordFailure } from "./guard";
import { b64, constantTimeEqual, parseCode, randomCode, sha256, unauthorized } from "./util";

export const PAIRING_CODE_TTL = 5 * 60_000;

const codeHash = async (code: string) => b64(await sha256(`pairing:${code}`));

/** 生成新的配对码，同时作废上一个。 */
export async function createPairingCode(deps: Deps): Promise<{ code: string; expiresAt: number }> {
  const code = randomCode();
  const expiresAt = deps.now() + PAIRING_CODE_TTL;
  deps.sql.run(`INSERT OR REPLACE INTO pairing_codes (id, code_hash, expires_at) VALUES (1, ?, ?)`, await codeHash(code), expiresAt);
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
  const row = one<{ code_hash: string; expires_at: number }>(deps.sql, `SELECT * FROM pairing_codes WHERE id = 1`);
  if (!code || !row || row.expires_at <= deps.now() || !constantTimeEqual(row.code_hash, hash)) {
    recordFailure(deps, net);
    throw unauthorized("配对码不对或已过期。请在管理设备的“设备 → 添加设备”中重新生成，或者不填配对码，改用扫码。");
  }
  return hash;
}

/** 在创建请求的事务里作废配对码；配对码已被别的请求用掉或换掉时抛错，整个事务回滚。 */
export function consumePairingCode(deps: Deps, hash: string) {
  const row = one<{ code_hash: string }>(deps.sql, `SELECT code_hash FROM pairing_codes WHERE id = 1`);
  if (row?.code_hash !== hash) throw unauthorized("配对码已经用过或已重新生成，请在管理设备上重新生成。");
  deps.sql.run(`DELETE FROM pairing_codes WHERE id = 1`);
}
