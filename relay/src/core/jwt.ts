// APNs（ES256）和 FCM（RS256）接入用的 JWT。这是苹果、谷歌规定的接入方式，不是 Harmonia 自己的签名格式。
import { b64, utf8 } from "./util";

/** PEM（PKCS#8）转 DER。控制台里粘贴的密钥可能把换行写成 \n，一并处理。 */
export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END) [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

const ALGORITHMS = {
  ES256: { import: { name: "ECDSA", namedCurve: "P-256" }, sign: { name: "ECDSA", hash: "SHA-256" } },
  RS256: { import: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, sign: { name: "RSASSA-PKCS1-v1_5" } },
} as const;

export type JwtAlg = keyof typeof ALGORITHMS;

/** 签发 JWT。WebCrypto 的 ECDSA 签名本身就是 JWS 要求的 r‖s 格式。 */
export async function signJwt(
  alg: JwtAlg,
  pem: string,
  header: Record<string, string>,
  claims: Record<string, string | number>,
): Promise<string> {
  const a = ALGORITHMS[alg];
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(pem), a.import, false, ["sign"]);
  const part = (v: object) => b64(utf8(JSON.stringify(v)));
  const input = `${part({ alg, typ: "JWT", ...header })}.${part(claims)}`;
  const sig = new Uint8Array(await crypto.subtle.sign(a.sign, key, utf8(input)));
  return `${input}.${b64(sig)}`;
}
