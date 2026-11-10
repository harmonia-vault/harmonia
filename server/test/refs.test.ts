import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { duplicateNames, expand, parseRefs, type Ref } from "../src/core/refs";
import { approvalGrantMsg, approvalRequestMsg, b64 } from "../src/core/util";

const A = "AAAAAAAAAAAAAAAAAAAAAA";
const B = "BBBBBBBBBBBBBBBBBBBBBB";
const names = (m: Record<string, string[]>) => (id: string) => m[id] ?? [];

describe("引用的解析", () => {
  it("拒绝不合规的引用", () => {
    expect(() => parseRefs([{ vaultId: A, scope: "some" }])).toThrow("范围");
    expect(() => parseRefs([{ vaultId: A, scope: "all", items: [{ name: "X" }] }])).toThrow("新的名字");
    expect(() => parseRefs([{ vaultId: A, scope: "pick", items: [{ name: "X", as: "1BAD" }] }])).toThrow();
    expect(() =>
      parseRefs([
        { vaultId: A, scope: "all" },
        { vaultId: A, scope: "pick", items: [] },
      ]),
    ).toThrow("只能引用一次");
    expect(() => parseRefs([{ vaultId: A, scope: "pick", items: [{ name: "X" }, { name: "X" }] }])).toThrow("重复");
  });

  it("勾选时 as 可以省略", () => {
    expect(parseRefs([{ vaultId: A, scope: "pick", items: [{ name: "X", as: "" }] }])).toEqual([
      { vaultId: A, scope: "pick", items: [{ name: "X" }] },
    ]);
  });
});

describe("展开最终名字", () => {
  it("按引用顺序展开，勾选只取存在的变量，全部变量按名字排序并应用改名", () => {
    const refs = parseRefs([
      { vaultId: A, scope: "pick", items: [{ name: "OPENAI_API_KEY", as: "LLM_KEY" }, { name: "MISSING" }] },
      { vaultId: B, scope: "all", items: [{ name: "Z", as: "ZED" }] },
    ]);
    const r = expand(refs, names({ [A]: ["OPENAI_API_KEY", "OTHER"], [B]: ["Z", "DB_URL"] }));
    expect(r.items).toEqual([
      { name: "LLM_KEY", vaultId: A, source: "OPENAI_API_KEY" },
      { name: "DB_URL", vaultId: B, source: "DB_URL" },
      { name: "ZED", vaultId: B, source: "Z" },
    ]);
    expect(r.shadowed).toEqual([]);
  });

  it("后来出现的重名由排在前面的引用提供，其余列为被遮住", () => {
    const refs = parseRefs([
      { vaultId: A, scope: "all" },
      { vaultId: B, scope: "all" },
    ]);
    const r = expand(refs, names({ [A]: ["K"], [B]: ["K", "J"] }));
    expect(r.items.map((i) => [i.name, i.vaultId])).toEqual([
      ["K", A],
      ["J", B],
    ]);
    expect(r.shadowed).toEqual([{ name: "K", vaultId: B, source: "K" }]);
  });

  it("保存时检查重名：勾选的不论是否存在都算", () => {
    const refs = parseRefs([
      { vaultId: A, scope: "pick", items: [{ name: "X", as: "K" }] },
      { vaultId: B, scope: "all" },
    ]);
    expect(duplicateNames(refs, names({ [B]: ["K", "J"] }))).toEqual(["K"]);
    expect(duplicateNames(refs, names({ [B]: ["J"] }))).toEqual([]);
  });
});

describe("三端共用的向量", () => {
  type Case = { name: string; refs: Ref[]; vaults: Record<string, string[]>; items: unknown[]; shadowed: unknown[]; duplicates: string[] };
  const { cases } = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../../vectors/refs.json"), "utf8")) as { cases: Case[] };
  for (const c of cases) {
    it(c.name, () => {
      const refs = parseRefs(c.refs);
      expect(expand(refs, names(c.vaults))).toEqual({ items: c.items, shadowed: c.shadowed });
      expect(duplicateNames(refs, names(c.vaults))).toEqual(c.duplicates);
    });
  }
});

describe("批准请求的签名原文与三端一致", () => {
  const v = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../../vectors/crypto.json"), "utf8"));
  const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
  it("请求和结果", async () => {
    const id = "CCCCCCCCCCCCCCCCCCCCCC";
    const dev = "AAAAAAAAAAAAAAAAAAAAAA";
    expect(hex(await approvalRequestMsg(id, dev, v.approval.detail, ""))).toBe(v.messages.approvalRequest);
    expect(hex(await approvalRequestMsg(id, dev, v.approval.detail, v.approval.payload))).toBe(v.messages.approvalWrite);
    expect(hex(await approvalGrantMsg(id, b64(new TextEncoder().encode("sealed"))))).toBe(v.messages.approvalGrant);
  });
});
