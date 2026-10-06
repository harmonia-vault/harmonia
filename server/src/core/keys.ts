// 设备证书与环境钥封装的校验（docs/protocol.md 2.2）。
import type { Sql } from "./db";
import { arr, bad, bin, decimal, deviceCertMsg, envelopeMsg, id, obj, verifyEd25519 } from "./util";

export type Envelope = { envId: string; keyVersion: number; recipient: string; sealed: string; sig: string };

export async function verifyCert(
  rootPub: string,
  deviceId: string,
  kind: string,
  signPub: string,
  boxPub: string,
  cert: string,
): Promise<void> {
  if (!(await verifyEd25519(rootPub, deviceCertMsg(deviceId, kind, signPub, boxPub), cert))) {
    throw bad("设备证书签名无效。");
  }
}

/** 解析并校验发给同一接收者的一组封装。 */
export async function parseEnvelopes(rootPub: string, recipient: string, raw: unknown): Promise<Envelope[]> {
  const out: Envelope[] = [];
  for (const item of arr(raw ?? [], "封装列表")) {
    const e = obj(item, "封装");
    const env: Envelope = {
      envId: id(e.envId, "环境 ID"),
      keyVersion: decimal(e.keyVersion, "密钥版本"),
      recipient,
      sealed: bin(e.sealed, "封装内容", 80),
      sig: bin(e.sig, "封装签名", 64),
    };
    if (!(await verifyEd25519(rootPub, await envelopeMsg(env.envId, env.keyVersion, recipient, env.sealed), env.sig))) {
      throw bad("封装签名无效。");
    }
    out.push(env);
  }
  if (new Set(out.map((e) => e.envId)).size !== out.length) throw bad("封装列表中有重复的环境。");
  return out;
}

/** 校验封装与当前环境的密钥版本一致。 */
export function checkKeyVersions(sql: Sql, envelopes: Envelope[]) {
  for (const e of envelopes) {
    const env = sql.all<{ key_version: number }>(`SELECT key_version FROM environments WHERE id = ?`, e.envId)[0];
    if (!env) throw bad("封装对应的环境不存在。");
    if (env.key_version !== e.keyVersion) throw bad("封装的密钥版本已过期，请同步后重试。");
  }
}

/** 封装必须恰好覆盖全部现存环境。 */
export function requireAllEnvironments(sql: Sql, envelopes: Envelope[]) {
  checkKeyVersions(sql, envelopes);
  const total = sql.all<{ n: number }>(`SELECT COUNT(*) AS n FROM environments`)[0]!.n;
  if (envelopes.length !== total) throw bad("需要为全部环境提供封装，请同步后重试。");
}

export function insertEnvelopes(sql: Sql, envelopes: Envelope[]) {
  for (const e of envelopes) {
    sql.run(
      `INSERT OR REPLACE INTO envelopes (env_id, key_version, recipient, sealed, sig) VALUES (?, ?, ?, ?, ?)`,
      e.envId,
      e.keyVersion,
      e.recipient,
      e.sealed,
      e.sig,
    );
  }
}
