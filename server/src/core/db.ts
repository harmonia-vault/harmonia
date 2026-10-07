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
const MIGRATIONS: string[][] = [
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
];

export function migrate(sql: Sql): void {
  sql.run(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`);
  const current = one<{ version: number }>(sql, `SELECT version FROM schema_version`)?.version ?? 0;
  for (let v = current; v < MIGRATIONS.length; v++) {
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
