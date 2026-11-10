// 环境对变量库的引用：解析、展开最终名字、检查重名（docs/protocol.md 3.2，设计文档 17.1）。
// 展开规则三端一致，见 vectors/refs.json。
import { arr, bad, id, obj, varName } from "./util";

export type RefItem = { name: string; as?: string };
export type Ref = { vaultId: string; scope: "all" | "pick"; items: RefItem[] };

/** 展开后的一项：name 是环境里的名字，source 是变量库里的原名。 */
export type Item = { name: string; vaultId: string; source: string };

const MAX_REFS = 50;
const MAX_ITEMS = 1000;

export function parseRefs(raw: unknown): Ref[] {
  const refs = arr(raw ?? [], "引用列表").map((v) => {
    const o = obj(v, "引用");
    const scope = o.scope;
    if (scope !== "all" && scope !== "pick") throw bad("引用的范围只能是 all 或 pick。");
    const items = arr(o.items ?? [], "引用的变量").map((x) => {
      const it = obj(x, "引用的变量");
      const name = varName(it.name);
      if (it.as === undefined || it.as === null || it.as === "") {
        if (scope === "all") throw bad(`范围是全部变量时，${name} 需要给出新的名字。`);
        return { name };
      }
      return { name, as: varName(it.as) };
    });
    if (items.length > MAX_ITEMS) throw bad(`一条引用最多列出 ${MAX_ITEMS} 个变量。`);
    if (new Set(items.map((i) => i.name)).size !== items.length) throw bad("同一条引用里有重复的变量。");
    return { vaultId: id(o.vaultId, "变量库 ID"), scope, items } as Ref;
  });
  if (refs.length > MAX_REFS) throw bad(`一个环境最多引用 ${MAX_REFS} 个变量库。`);
  if (new Set(refs.map((r) => r.vaultId)).size !== refs.length) throw bad("同一个变量库在环境里只能引用一次。");
  return refs;
}

/** 这条引用是否包含变量库里名为 source 的变量。 */
export function covers(ref: Ref, source: string): boolean {
  return ref.scope === "all" || ref.items.some((i) => i.name === source);
}

function nameIn(ref: Ref, source: string): string {
  return ref.items.find((i) => i.name === source)?.as ?? source;
}

/**
 * 按引用顺序展开最终名字。names(vaultId) 返回变量库里现存的变量名（不存在的变量库返回空）。
 * 同名时排在前面的优先，其余放进 shadowed。
 */
export function expand(refs: Ref[], names: (vaultId: string) => string[]): { items: Item[]; shadowed: Item[] } {
  const items: Item[] = [];
  const shadowed: Item[] = [];
  const seen = new Set<string>();
  for (const ref of refs) {
    const existing = new Set(names(ref.vaultId));
    const sources = ref.scope === "all" ? [...existing].sort() : ref.items.map((i) => i.name).filter((n) => existing.has(n));
    for (const source of sources) {
      const item = { name: nameIn(ref, source), vaultId: ref.vaultId, source };
      if (seen.has(item.name)) shadowed.push(item);
      else {
        seen.add(item.name);
        items.push(item);
      }
    }
  }
  return { items, shadowed };
}

/**
 * 保存环境时检查重名：勾选的变量不论是否存在都算，全部变量按现存的变量算。
 * 返回重复的最终名字（按出现顺序，不重复列出）。
 */
export function duplicateNames(refs: Ref[], names: (vaultId: string) => string[]): string[] {
  const seen = new Set<string>();
  const dup: string[] = [];
  for (const ref of refs) {
    const sources = ref.scope === "all" ? [...new Set(names(ref.vaultId))].sort() : ref.items.map((i) => i.name);
    for (const source of sources) {
      const name = nameIn(ref, source);
      if (seen.has(name)) {
        if (!dup.includes(name)) dup.push(name);
      } else seen.add(name);
    }
  }
  return dup;
}
