// 存储接口与单个账号的表结构。Durable Object 与 Node（node:sqlite）都提供同步 SQL，因此共用同一套语句。

export type Row = Record<string, string | number | null>;
export type Param = string | number | null;

export interface Sql {
  all<T = Row>(query: string, ...params: Param[]): T[];
  run(query: string, ...params: Param[]): void;
  /** 在一个原子事务中执行；fn 内只能做同步操作。 */
  transaction<T>(fn: () => T): T;
}

export function one<T = Row>(sql: Sql, query: string, ...params: Param[]): T | undefined {
  return sql.all<T>(query, ...params)[0];
}

/** 按顺序执行的表结构迁移；只追加，不修改已发布的条目。 */
export const MIGRATIONS: string[][] = [
  [
    `CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)`,
    `INSERT INTO meta (key, value) VALUES ('head_seq', 0)`,
    `CREATE TABLE account (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      account_id TEXT NOT NULL,
      email TEXT NOT NULL,
      status TEXT NOT NULL,
      kdf_salt TEXT NOT NULL,
      auth_salt TEXT NOT NULL,
      auth_hash TEXT NOT NULL,
      root_pub TEXT,
      recovery_generation INTEGER,
      recovery_sign_pub TEXT,
      recovery_box_pub TEXT,
      root_recovery_sealed TEXT,
      root_recovery_sig TEXT,
      created_at INTEGER NOT NULL
    )`,
    `CREATE TABLE email_codes (
      purpose TEXT PRIMARY KEY,
      code_hash TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL,
      sent_at INTEGER NOT NULL
    )`,
    `CREATE TABLE devices (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      kind TEXT NOT NULL,
      sign_pub TEXT NOT NULL,
      box_pub TEXT NOT NULL,
      cert TEXT NOT NULL,
      root_sealed TEXT,
      status TEXT NOT NULL,
      rotation_required INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL
    )`,
    `CREATE TABLE pairings (
      id TEXT PRIMARY KEY,
      secret_hash TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      sign_pub TEXT NOT NULL,
      box_pub TEXT NOT NULL,
      root_pub TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`,
    `CREATE TABLE environments (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      key_version INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )`,
    `CREATE TABLE envelopes (
      env_id TEXT NOT NULL,
      key_version INTEGER NOT NULL,
      recipient TEXT NOT NULL,
      sealed TEXT NOT NULL,
      sig TEXT NOT NULL,
      PRIMARY KEY (env_id, key_version, recipient)
    )`,
    `CREATE TABLE grants (
      device_id TEXT NOT NULL,
      env_id TEXT NOT NULL,
      role TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      seq INTEGER NOT NULL,
      PRIMARY KEY (device_id, env_id)
    )`,
    `CREATE TABLE variables (
      env_id TEXT NOT NULL,
      name TEXT NOT NULL,
      value TEXT NOT NULL,
      key_version INTEGER NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      seq INTEGER NOT NULL,
      updated_by TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (env_id, name)
    )`,
    `CREATE INDEX variables_seq ON variables (seq)`,
    `CREATE TABLE sessions (
      token_hash TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      device_id TEXT,
      expires_at INTEGER NOT NULL
    )`,
    `CREATE TABLE challenges (
      nonce TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      device_id TEXT,
      expires_at INTEGER NOT NULL
    )`,
    `CREATE TABLE idempotency (
      device_id TEXT NOT NULL,
      key TEXT NOT NULL,
      request_hash TEXT NOT NULL,
      response TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, key)
    )`,
    `CREATE TABLE rate_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start INTEGER NOT NULL)`,
  ],
  [
    `ALTER TABLE pairings ADD COLUMN ip TEXT NOT NULL DEFAULT ''`,
    `CREATE TABLE pairing_blocks (ip TEXT PRIMARY KEY, until INTEGER NOT NULL)`,
  ],
  [`ALTER TABLE pairings ADD COLUMN can_manage INTEGER NOT NULL DEFAULT 0`],
  [
    `ALTER TABLE grants ADD COLUMN active INTEGER NOT NULL DEFAULT 1`,
    `ALTER TABLE grants ADD COLUMN position INTEGER NOT NULL DEFAULT 0`,
    `UPDATE grants SET position = (SELECT COUNT(*) FROM grants g WHERE g.device_id = grants.device_id AND g.rowid < grants.rowid)`,
  ],
  [
    `CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
    `DROP TABLE email_codes`,
    `CREATE TABLE email_flows (
      flow_hash TEXT PRIMARY KEY,
      purpose TEXT NOT NULL,
      net TEXT NOT NULL,
      code_hash TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL
    )`,
    `CREATE TABLE mail_log (at INTEGER NOT NULL, net TEXT NOT NULL, kind TEXT NOT NULL)`,
    `CREATE TABLE login_failures (net TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start INTEGER NOT NULL, next_at INTEGER NOT NULL)`,
    `CREATE TABLE login_events (at INTEGER NOT NULL)`,
  ],
  [`ALTER TABLE devices ADD COLUMN system_vars INTEGER NOT NULL DEFAULT 0`],
  // 去掉账号密码；配对请求区分匿名与配对码创建；配对码与输错计数（docs/protocol.md 3.2、3.8）。
  [
    `DELETE FROM sessions WHERE kind = 'password'`,
    `ALTER TABLE account DROP COLUMN kdf_salt`,
    `ALTER TABLE account DROP COLUMN auth_salt`,
    `ALTER TABLE account DROP COLUMN auth_hash`,
    `DROP TABLE login_failures`,
    `DROP TABLE login_events`,
    `DELETE FROM kv WHERE key = 'login_attack'`,
    `DELETE FROM email_flows WHERE purpose IN ('login', 'password')`,
    `DELETE FROM mail_log WHERE kind = 'login'`,
    `ALTER TABLE pairings ADD COLUMN authorized INTEGER NOT NULL DEFAULT 0`,
    `CREATE TABLE pairing_codes (id INTEGER PRIMARY KEY CHECK (id = 1), code_hash TEXT NOT NULL, expires_at INTEGER NOT NULL)`,
    `CREATE TABLE code_failures (net TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start INTEGER NOT NULL, next_at INTEGER NOT NULL)`,
  ],
  [`ALTER TABLE devices ADD COLUMN version TEXT NOT NULL DEFAULT ''`],
  // 去掉 admin 权限，原有的 admin 授权改为读写（docs/protocol.md 4）。
  [`UPDATE grants SET role = 'rw' WHERE role = 'admin'`],
  // 配对码可以同时有多个，有效期可选（docs/protocol.md 3.2）。
  [
    `DROP TABLE pairing_codes`,
    `CREATE TABLE pairing_codes (code_hash TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)`,
  ],
  // CLI 的自动更新开关（docs/protocol.md 3.2）。
  [`ALTER TABLE devices ADD COLUMN auto_update INTEGER NOT NULL DEFAULT 0`],
  // 两层结构：原来的环境改为同 ID、同名的变量库（变量的 AAD 用的就是这个 ID），再建一个同 ID、同名、
  // 引用全部变量并可以修改的环境；原有授权转到环境上并开启本机解密（docs/rewrite-plan.md 17.3）。
  // visibility_seq 记录设备能看到的变量范围最近一次变化，用于决定同步是否下发完整列表（docs/protocol.md 3.4）。
  [
    `ALTER TABLE environments RENAME TO vaults`,
    `ALTER TABLE envelopes RENAME COLUMN env_id TO vault_id`,
    `ALTER TABLE variables RENAME COLUMN env_id TO vault_id`,
    `CREATE TABLE environments (id TEXT PRIMARY KEY, name TEXT NOT NULL, refs TEXT NOT NULL, created_at INTEGER NOT NULL)`,
    `INSERT INTO environments (id, name, refs, created_at)
     SELECT id, name, '[{"vaultId":"' || id || '","scope":"all","writable":true,"items":[]}]', created_at FROM vaults`,
    `ALTER TABLE grants RENAME COLUMN env_id TO environment_id`,
    `ALTER TABLE grants ADD COLUMN local_decrypt INTEGER NOT NULL DEFAULT 1`,
    `ALTER TABLE devices ADD COLUMN visibility_seq INTEGER NOT NULL DEFAULT 0`,
  ],
  // 手机批准解密与写入（docs/protocol.md 3.9）。authorizations 是正在生效的授权，只用于显示和结束；
  // env_refs 记下批准时各环境的引用，引用改变时结束授权。
  [
    `CREATE TABLE approvals (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      detail TEXT NOT NULL,
      payload TEXT NOT NULL,
      sig TEXT NOT NULL,
      status TEXT NOT NULL,
      result TEXT,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`,
    `CREATE TABLE authorizations (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL,
      items TEXT NOT NULL,
      env_refs TEXT NOT NULL,
      scope TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )`,
  ],
];

/** 执行迁移；upTo 只给测试用，迁移到指定版本为止。 */
export function migrate(sql: Sql, upTo = MIGRATIONS.length): void {
  sql.run(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`);
  const current = one<{ version: number }>(sql, `SELECT version FROM schema_version`)?.version ?? 0;
  for (let v = current; v < upTo; v++) {
    sql.transaction(() => {
      for (const stmt of MIGRATIONS[v]!) sql.run(stmt);
      sql.run(`DELETE FROM schema_version`);
      sql.run(`INSERT INTO schema_version (version) VALUES (?)`, v + 1);
    });
  }
}

/** 全局单调序号：每次状态变更递增，并返回新值。 */
export function bump(sql: Sql): number {
  sql.run(`UPDATE meta SET value = value + 1 WHERE key = 'head_seq'`);
  return headSeq(sql);
}

export function headSeq(sql: Sql): number {
  return one<{ value: number }>(sql, `SELECT value FROM meta WHERE key = 'head_seq'`)!.value;
}

/** 清空账号的全部数据（重置账号）。 */
export function wipe(sql: Sql): void {
  const tables = sql.all<{ name: string }>(
    `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('schema_version', 'meta', '_cf_KV')`,
  );
  sql.transaction(() => {
    for (const t of tables) sql.run(`DELETE FROM "${t.name}"`);
  });
}
