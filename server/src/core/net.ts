// 限流与风控的计数单位“网络”，以及只保存其 HMAC 的标识（docs/protocol.md 3.8）。
import { b64, utf8 } from "./util";

/** IPv4 按单个地址；IPv6 按 /64，wide 时按 /48。无法识别的地址原样返回。 */
export function network(ip: string, wide = false): string {
  if (!ip.includes(":")) return ip;
  const zone = ip.split("%")[0]!.toLowerCase();
  const [head, tail] = zone.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  // 末尾是 IPv4 写法（例如 ::ffff:1.2.3.4）时，前 64 位里不会出现它，按两组计入长度即可。
  const size = (parts: string[]) => parts.reduce((n, p) => n + (p.includes(".") ? 2 : 1), 0);
  const groups = zone.includes("::") ? [...left, ...Array(8 - size(left) - size(right)).fill("0"), ...right] : left;
  return groups
    .slice(0, wide ? 3 : 4)
    .map((g) => g.replace(/^0+(?=.)/, ""))
    .join(":");
}

/** 网络标识：HMAC-SHA256(密钥, 网络) 的前 16 字节，不保存原始地址。 */
export async function networkId(secret: string, ip: string, wide = false): Promise<string> {
  const key = await crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(network(ip, wide))));
  return b64(mac.slice(0, 16));
}
