# 开发规则

本仓库是 Harmonia 的唯一开发仓库：`server/`（Cloudflare Workers）、`cli/`（Go，Linux/macOS）、`app/`（Flutter，Android）。

## 事实来源

- 设计：[docs/rewrite-plan.md](docs/rewrite-plan.md)；协议：[docs/protocol.md](docs/protocol.md)；验收：[docs/acceptance.md](docs/acceptance.md)。
- 改动 API、数据格式、安全口径或用户流程前，先更新 `docs/` 并经用户确认。

## 规则

1. 使用简体中文写文档、注释和界面文案；协议字段和代码标识保留英文。
2. 工具版本写在根目录 `mise.toml` 的 `[tools]`，任务写在 `[tasks]`，通过 `mise run <task>` 执行。
3. 完成标准是相关用户流程能闭环，不以测试数量为准；产品验收由用户在真机上进行。
4. 1.0 之前不做向后兼容，不保留并行版本；类型名和路由不加 `v2`、`v5` 之类的后缀（`/api/v1` 前缀除外）。
5. 不新增密码学结构：协议第 2 节之外的签名或加密格式需用户批准。改动加密实现后运行 `mise run vectors` 和三端测试。
6. 不写没有入口的功能：每个公开方法都要有界面或命令调用方。
7. 单文件超过 500 行时拆分；单个里程碑新增代码超过约 5,000 行时停下确认。
8. 不提交证据、验证记录、状态流水；`docs/` 只放设计。
9. 界面和 CLI 输出不出现内部术语，错误信息要说明下一步怎么做。
10. 不写 UI 单元测试；核心逻辑（`app/lib/core`、`cli/internal`、`server/src/core`）要有单元测试。
11. 只使用合成账号和测试数据，不读取或提交真实凭据。
