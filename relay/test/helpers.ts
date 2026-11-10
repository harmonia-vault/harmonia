// 测试工具：node:sqlite 存储与测试用密钥。
import { DatabaseSync } from "node:sqlite";
import { migrate, type Param, type Sql } from "../src/core/db";

export function nodeSql(): Sql {
  const db = new DatabaseSync(":memory:");
  let depth = 0;
  const sql: Sql = {
    all: <T>(q: string, ...p: Param[]) => db.prepare(q).all(...p) as T[],
    run: (q: string, ...p: Param[]) => void db.prepare(q).run(...p),
    transaction: <T>(fn: () => T): T => {
      if (depth > 0) return fn();
      depth++;
      db.exec("BEGIN");
      try {
        const r = fn();
        db.exec("COMMIT");
        return r;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      } finally {
        depth--;
      }
    },
  };
  migrate(sql);
  return sql;
}

/** 生成一把测试用私钥，返回 PKCS#8 PEM 和用于验签的公钥。 */
export async function testKey(alg: "ES256" | "RS256") {
  const params =
    alg === "ES256"
      ? { name: "ECDSA", namedCurve: "P-256" }
      : { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  const pair = (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/.{64}/g, "$&\n")}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

export function decodeJwt(jwt: string) {
  const [h, c, s] = jwt.split(".") as [string, string, string];
  const json = (x: string) => JSON.parse(Buffer.from(x, "base64url").toString("utf8"));
  return { header: json(h), claims: json(c), input: `${h}.${c}`, sig: new Uint8Array(Buffer.from(s, "base64url")) };
}
