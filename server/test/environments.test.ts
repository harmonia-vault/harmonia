import { describe, expect, it } from "vitest";
import { migrate, MIGRATIONS } from "../src/core/db";
import { b64 } from "../src/core/util";
import { newId, nodeSql, pairClient, rand, TestAccount, TestServer } from "./helpers";

const put = (s: TestServer, token: string, vault: string, name: string) =>
  s.call("PUT", `/api/v1/vaults/${vault}/variables/${name}`, {
    token,
    body: { value: b64(rand(60)), keyVersion: "1" },
    headers: { "idempotency-key": newId() },
  });

const sync = (s: TestServer, token: string, since = 0) => s.ok("GET", `/api/v1/sync?since=${since}`, { token });

/** 两个变量库：共享密钥（OPENAI_API_KEY、OTHER）、博客生产（DB_URL）。 */
async function setup() {
  const s = new TestServer();
  const a = await TestAccount.create(s);
  const shared = await a.createVault(s, [a.phone.id], "共享密钥");
  const blog = await a.createVault(s, [a.phone.id], "博客生产");
  for (const n of ["OPENAI_API_KEY", "OTHER"]) expect((await put(s, a.phone.token, shared, n)).status).toBe(200);
  expect((await put(s, a.phone.token, blog, "DB_URL")).status).toBe(200);
  const env = await a.createEnvironment(
    s,
    [
      { vaultId: shared, scope: "pick", writable: false, items: [{ name: "OPENAI_API_KEY", as: "LLM_KEY" }] },
      { vaultId: blog, scope: "all", writable: true, items: [] },
    ],
    "博客",
  );
  return { s, a, shared, blog, env };
}

describe("两层结构", () => {
  it("环境按引用展开：改名、部分引用只下发选中的变量，可写范围和新增变量的变量库", async () => {
    const { s, a, shared, blog, env } = await setup();
    const cli = await pairClient(s, a, [{ environmentId: env, role: "rw" }], [shared, blog]);
    const r = await sync(s, cli.token);
    expect(r.full).toBe(true);
    const e = r.environments[0];
    expect(e.items).toEqual([
      { name: "LLM_KEY", vaultId: shared, source: "OPENAI_API_KEY", writable: false },
      { name: "DB_URL", vaultId: blog, source: "DB_URL", writable: true },
    ]);
    expect(e.createVaults).toEqual([blog]);
    expect(r.vaultNames).toEqual([
      { id: shared, name: "共享密钥" },
      { id: blog, name: "博客生产" },
    ]);
    // OTHER 没有被引用，不下发密文。
    expect(r.variables.map((v: { name: string }) => v.name).sort()).toEqual(["DB_URL", "OPENAI_API_KEY"]);
    // 不可修改的引用不能写；可以修改的全部变量引用能改也能新增。
    expect((await put(s, cli.token, shared, "OPENAI_API_KEY")).status).toBe(403);
    expect((await put(s, cli.token, blog, "DB_URL")).status).toBe(200);
    expect((await put(s, cli.token, blog, "NEW_ONE")).status).toBe(200);
    const inc = await sync(s, cli.token, r.seq);
    expect(inc.full).toBe(false);
    expect(inc.variables.map((v: { name: string }) => v.name).sort()).toEqual(["DB_URL", "NEW_ONE"]);
  });

  it("保存环境时最终名字不能重复", async () => {
    const { s, a, shared, blog } = await setup();
    const r = await s.call("POST", "/api/v1/environments", {
      token: a.phone.token,
      body: {
        id: newId(),
        name: "冲突",
        refs: [
          { vaultId: shared, scope: "pick", writable: false, items: [{ name: "OTHER", as: "DB_URL" }] },
          { vaultId: blog, scope: "all", writable: false, items: [] },
        ],
      },
    });
    expect([r.status, r.json.error]).toEqual([409, "conflict"]);
    expect(r.json.message).toContain("DB_URL");
    const missing = await s.call("POST", "/api/v1/environments", {
      token: a.phone.token,
      body: { id: newId(), name: "x", refs: [{ vaultId: newId(), scope: "all", writable: false, items: [] }] },
    });
    expect(missing.status).toBe(400);
  });

  it("没有开启本机解密时不给封装、不下发密文，也不能直接写入", async () => {
    const { s, a, blog, env } = await setup();
    const cli = await pairClient(s, a, [{ environmentId: env, role: "rw", localDecrypt: false }]);
    const r = await sync(s, cli.token);
    expect(r.environments[0].localDecrypt).toBe(false);
    expect(r.environments[0].items.map((i: { name: string }) => i.name)).toEqual(["LLM_KEY", "DB_URL"]);
    expect([r.vaults, r.envelopes, r.variables]).toEqual([[], [], []]);
    expect((await put(s, cli.token, blog, "DB_URL")).status).toBe(403);
    // 授权时附带封装会被拒绝。
    const bad = await s.call("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ environmentId: env, role: "rw", localDecrypt: false }], envelopes: [await a.envelope(blog, cli.id)] },
    });
    expect(bad.status).toBe(400);
  });

  it("开启本机解密要附带全部引用的封装；环境新增引用时补封装，去掉引用时删除封装并下发完整列表", async () => {
    const { s, a, shared, blog, env } = await setup();
    const cli = await pairClient(s, a, [{ environmentId: env, role: "ro", localDecrypt: false }]);
    const half = await s.call("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: { grants: [{ environmentId: env, role: "ro", localDecrypt: true }], envelopes: [await a.envelope(blog, cli.id)] },
    });
    expect(half.status).toBe(400);
    await s.ok("PUT", `/api/v1/devices/${cli.id}/grants`, {
      token: a.phone.token,
      body: {
        grants: [{ environmentId: env, role: "ro", localDecrypt: true }],
        envelopes: [await a.envelope(blog, cli.id), await a.envelope(shared, cli.id)],
      },
    });
    const first = await sync(s, cli.token);
    expect(first.envelopes).toHaveLength(2);

    const third = await a.createVault(s, [a.phone.id], "第三个");
    expect((await put(s, a.phone.token, third, "T")).status).toBe(200);
    const refs = [
      { vaultId: blog, scope: "all", writable: true, items: [] },
      { vaultId: third, scope: "all", writable: false, items: [] },
    ];
    const noEnvelope = await s.call("PUT", `/api/v1/environments/${env}`, { token: a.phone.token, body: { name: "博客", refs } });
    expect(noEnvelope.status).toBe(400);
    await s.ok("PUT", `/api/v1/environments/${env}`, {
      token: a.phone.token,
      body: { name: "博客", refs, envelopes: [{ ...(await a.envelope(third, cli.id)), recipient: cli.id }] },
    });
    const after = await sync(s, cli.token, first.seq);
    expect(after.full).toBe(true);
    expect(after.envelopes.map((e: { vaultId: string }) => e.vaultId).sort()).toEqual([blog, third].sort());
    expect(after.variables.map((v: { name: string }) => v.name).sort()).toEqual(["DB_URL", "T"]);
  });

  it("删除变量库后引用标记为已失效；删除环境只删授权，变量库还在", async () => {
    const { s, a, shared, blog, env } = await setup();
    const cli = await pairClient(s, a, [{ environmentId: env, role: "ro" }], [shared, blog]);
    await s.ok("DELETE", `/api/v1/vaults/${shared}`, { token: a.phone.token });
    const m = await sync(s, a.phone.token);
    const refs = m.manager.environments.find((e: { id: string }) => e.id === env).refs;
    expect(refs.map((r: { missing: boolean }) => r.missing)).toEqual([true, false]);
    const c = await sync(s, cli.token);
    expect(c.environments[0].items.map((i: { name: string }) => i.name)).toEqual(["DB_URL"]);
    expect(c.envelopes.map((e: { vaultId: string }) => e.vaultId)).toEqual([blog]);
    // 保留已失效的引用可以保存；新加一个不存在的变量库不行。
    await s.ok("PUT", `/api/v1/environments/${env}`, {
      token: a.phone.token,
      body: { name: "博客", refs: refs.map(({ missing: _, ...r }: { missing: boolean }) => r) },
    });
    await s.ok("DELETE", `/api/v1/environments/${env}`, { token: a.phone.token });
    const gone = await sync(s, cli.token);
    expect([gone.environments, gone.envelopes]).toEqual([[], []]);
    expect((await sync(s, a.phone.token)).manager.vaults.map((v: { id: string }) => v.id)).toEqual([blog]);
  });
});

describe("升级转换", () => {
  it("原来的环境变成同 ID 的变量库和引用全部变量的环境，授权开启本机解密", () => {
    const sql = nodeSql();
    migrate(sql, MIGRATIONS.findIndex((m) => m.some((q) => q.includes("RENAME TO vaults"))));
    sql.run(`INSERT INTO environments (id, name, key_version, created_at) VALUES ('E1', 'OpenAI', 1, 5)`);
    sql.run(`INSERT INTO envelopes (env_id, key_version, recipient, sealed, sig) VALUES ('E1', 1, 'D1', 's', 'g')`);
    sql.run(
      `INSERT INTO variables (env_id, name, value, key_version, deleted, seq, updated_by, updated_at) VALUES ('E1', 'K', 'v', 1, 0, 3, 'D1', 0)`,
    );
    sql.run(`INSERT INTO grants (device_id, env_id, role, expires_at, seq, active, position) VALUES ('D1', 'E1', 'rw', 0, 2, 0, 0)`);
    migrate(sql);
    expect(sql.all(`SELECT id, name, key_version FROM vaults`)).toEqual([{ id: "E1", name: "OpenAI", key_version: 1 }]);
    const envs = sql.all<{ id: string; name: string; refs: string }>(`SELECT id, name, refs FROM environments`);
    expect(envs.map((e) => [e.id, e.name, JSON.parse(e.refs)])).toEqual([
      ["E1", "OpenAI", [{ vaultId: "E1", scope: "all", writable: true, items: [] }]],
    ]);
    expect(sql.all(`SELECT environment_id, role, local_decrypt, active FROM grants`)).toEqual([
      { environment_id: "E1", role: "rw", local_decrypt: 1, active: 0 },
    ]);
    expect(sql.all(`SELECT vault_id FROM envelopes`)).toEqual([{ vault_id: "E1" }]);
    expect(sql.all(`SELECT vault_id, name FROM variables`)).toEqual([{ vault_id: "E1", name: "K" }]);
  });
});
