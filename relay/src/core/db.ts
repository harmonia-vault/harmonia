// 存储接口与表结构。Durable Object 与 Node（node:sqlite）都提供同步 SQL，因此共用同一套语句。

export type Param = string | number | null;

export interface Sql {
  all<T>(query: string, ...params: Param[]): T[];
  run(query: string, ...params: Param[]): void;
  /** 在一个原子事务中执行；fn 内只能做同步操作。 */
  transaction<T>(fn: () => T): T;
}

export function one<T>(sql: Sql, query: string, ...params: Param[]): T | undefined {
  return sql.all<T>(query, ...params)[0];
}

/** 按顺序执行的表结构迁移；只追加，不修改已发布的条目。 */
const MIGRATIONS: string[][] = [
  [
    // 只保存句柄的 SHA-256；refreshed_at 是最近一次登记或确认的时间，超过 90 天删除。
    `CREATE TABLE registrations (
      handle_hash TEXT PRIMARY KEY,
      platform TEXT NOT NULL,
      token TEXT NOT NULL,
      apns_env TEXT,
      created_at INTEGER NOT NULL,
      refreshed_at INTEGER NOT NULL
    )`,
    `CREATE INDEX registrations_refreshed ON registrations (refreshed_at)`,
    // 固定窗口计数：key 为用途加对象，例如 day:<句柄哈希>、global、register-min:<网络>。
    `CREATE TABLE counters (key TEXT PRIMARY KEY, count INTEGER NOT NULL, window_start INTEGER NOT NULL)`,
    `CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  ],
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
