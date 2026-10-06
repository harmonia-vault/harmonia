# Harmonia 协议

本文是服务端、CLI、App 三端共同遵守的合同。改动本文需先经用户确认（见 AGENTS.md）。设计背景见 [rewrite-plan.md](rewrite-plan.md)。

## 1. 编码约定

| 项 | 规则 |
| --- | --- |
| 二进制 | base64url，无填充（下文记作 b64） |
| ID | 16 字节随机数的 b64，22 个字符，匹配 `^[A-Za-z0-9_-]{22}$` |
| 变量名 | `^[A-Za-z_][A-Za-z0-9_]{0,127}$`，不能以 `__HARMONIA_` 开头（不区分大小写） |
| 变量值 | UTF-8，最长 65536 字节，可以为空 |
| 环境名、设备名 | 去除首尾空白后 1–64 个字符 |
| 时间 | Unix 毫秒整数 |
| 规范数组 | 字符串数组的紧凑 JSON 的 UTF-8 字节，记作 `C([...])`。数组元素只允许 ASCII 可打印字符（ID、b64、十进制数字、固定单词），因此 Go、Dart、JS 的输出一致 |

## 2. 密码学

全部使用 libsodium 兼容的标准构件。

| 用途 | 构件 |
| --- | --- |
| 变量值加密 | XChaCha20-Poly1305-IETF。密文 = b64(nonce24 ‖ ciphertext ‖ tag16)。AAD = `C(["harmonia.value", envId, keyVersion, name])` |
| 封装 | libsodium `crypto_box_seal`（X25519 + XSalsa20-Poly1305） |
| 加密密钥对 | 由 32 字节种子按 `crypto_box_seed_keypair` 派生：sk = SHA-512(seed)[0:32]，pk = X25519(sk, 基点) |
| 签名 | Ed25519，由 32 字节种子派生（`crypto_sign_seed_keypair`） |
| 密码 | Argon2id（`crypto_pwhash` argon2id13，ops=3，mem=64 MiB，并行度 1），salt 16 字节，输出 32 字节 = authKey |
| 派生 | HKDF-SHA256，salt 为空，输出 32 字节 |
| 摘要 | SHA-256 |

### 2.1 密钥

| 密钥 | 生成 | 持有者 |
| --- | --- | --- |
| 账号根签名钥（root） | 32 字节随机种子 → Ed25519 | 全部管理设备；另封装给恢复钥。`rootPub` 公开 |
| 设备签名钥 | 32 字节随机种子 → Ed25519 | 设备自己 |
| 设备加密钥 | 32 字节随机种子 → box 密钥对 | 设备自己 |
| 环境钥 | 32 字节随机数 | 管理设备、获授权设备、恢复钥（都是封装形式） |
| 恢复码 | 16 字节随机数 | 用户离线保存 |
| 恢复签名钥 | HKDF(恢复码, info=`harmonia.recovery.sign`) → Ed25519 种子 | 由恢复码派生 |
| 恢复加密钥 | HKDF(恢复码, info=`harmonia.recovery.box`) → box 种子 | 由恢复码派生 |

恢复码的显示格式：16 字节做 RFC 4648 Base32 编码（大写、无填充），得到 26 个字符，每 4 个字符用 `-` 分组。解析时去掉 `-` 和空白，转为大写，把 `0` 视为 `O`、`1` 视为 `I`。

### 2.2 签名

全项目只有以下签名，原文均为规范数组：

| 名称 | 原文 | 签名者 | 验证者 |
| --- | --- | --- | --- |
| 设备证书 | `C(["harmonia.device", deviceId, kind, signPub, boxPub])` | root | 管理设备：为某设备封装任何东西之前必须验证 |
| 封装签名 | `C(["harmonia.envelope", envId, keyVersion, recipient, b64(SHA-256(sealed))])` | root | 接收方：使用环境钥之前必须验证 |
| 恢复根封装签名 | `C(["harmonia.root-recovery", generation, b64(SHA-256(sealed))])` | 恢复签名钥 | 恢复中的设备 |
| 设备登录 | `C(["harmonia.auth", deviceId, nonce])` | 设备签名钥 | 服务端 |
| 恢复登录 | `C(["harmonia.recovery-auth", nonce])` | 恢复签名钥 | 服务端 |

`kind` 取 `manager` 或 `client`；`recipient` 为设备 ID 或字面量 `recovery`；`keyVersion`、`generation` 为十进制字符串。

管理设备收到的 root 封装（内容为 root 种子）不需要签名：解封后由种子派生公钥，必须等于本机钉住的 `rootPub`。

### 2.3 信任锚：rootPub 钉住

- 每台设备在第一次接触账号时读取 `rootPub` 并保存在本地，此后不再接受变更：首次初始化时由本机生成；登录后从 `GET /account` 读取；恢复时由恢复码解开的 root 种子推出。
- 配对请求中包含设备钉住的 `rootPub`，并纳入配对指纹。管理设备在批准前检查它是否等于真实的 `rootPub`，不一致就拒绝（提示服务器可能被篡改）。
- 因此，服务器无法偷换封装：封装必须由 root 签名；也无法塞入假设备：设备证书必须由 root 签名。

### 2.4 配对指纹

```
fp = SHA-256(C(["harmonia.pairing", pairingId, signPub, boxPub, rootPub]))
核对码 = Base32(fp[0:10])，16 个字符，按 4 个一组用 '-' 分隔
二维码内容 = "harmonia-pair:" + pairingId + ":" + b64(fp)
```

## 3. HTTP API

- 基础路径为 `/api/v1`。请求和响应都是 JSON，只允许 HTTPS（本地开发时允许 `http://localhost`、`http://127.0.0.1`）。
- 错误响应：`{"error": "<code>", "message": "<中文说明>"}`。

### 3.0 账号与寻址

- 一个实例可以有多个相互隔离的账号，账号以**邮箱**标识。服务端为每个账号使用一个独立的 Durable Object，另有一个目录 Durable Object 负责“邮箱 → 账号 ID”的映射和注册策略。
- 注册策略由两个部署变量控制：
  - `ALLOW_REGISTRATION`：为 `false` 时只允许注册第一个账号。
  - `REQUIRE_EMAIL_VERIFICATION`：为 `true` 时注册需要验证邮箱（默认 `true`）。
- 账号状态：
  - `pending`：邮箱未验证。15 分钟内不验证，该注册作废，可以重新注册。
  - `active`：可以登录。
  - `initialized`：已在手机上完成密钥初始化，账号公钥 `rootPub` 确定。
- 寻址方式：
  - 会话令牌的格式为 `<accountId>.<随机串>`，服务端据此定位账号。
  - 不带令牌的账号内请求（设备登录、配对状态查询、恢复登录），在请求头 `X-Harmonia-Account` 中给出账号 ID。
  - 以邮箱为入口的请求（注册、登录、找回密码、重置账号、开始恢复），由目录解析邮箱。
- 邮件验证码：8 位，字符取自 Base32 字母表，不区分大小写；15 分钟内有效；每个验证码最多尝试 5 次；重发间隔不少于 60 秒。用途包括注册验证、找回密码、重置账号。

### 3.1 会话

| 类型 | 获取方式 | 有效期 | 允许的操作 |
| --- | --- | --- | --- |
| password | `POST /auth/login` | 15 分钟 | 查看账号信息、首次初始化密钥、创建配对请求 |
| device | `POST /auth/device-session` | 1 小时 | 按设备当前的权限 |
| recovery | `POST /recovery/session` | 15 分钟 | 读取恢复材料、登记本机 |

`rotationRequired=true` 的管理设备只允许调用：`/sync`、`/events`、`/account`、`/recovery/rotate*`、`/devices/self/revoke`。

### 3.2 端点

**以邮箱为入口（由目录解析）：**

| 方法与路径 | 说明 |
| --- | --- |
| `GET /instance` | `{product:"harmonia", version, protocol:1, registration:{open, emailVerification}}` |
| `POST /register` | `{email, kdfSalt, authKey}` → `{accountId, verificationRequired}`。邮箱已被注册时返回 `conflict`，注册未开放时返回 `forbidden` |
| `POST /register/verify` | `{email, code}` → `{ok}` |
| `POST /register/resend` | `{email}` → `{ok}` |
| `GET /auth/prelogin?email=` | `{kdfSalt, opsLimit, memLimit}` |
| `POST /auth/login` | `{email, authKey}` → `{token, expiresAt, accountId}`；邮箱未验证时返回 `email_unverified` |
| `POST /password-reset/request` | `{email}` → `{ok}`，发送找回密码验证码 |
| `POST /password-reset/complete` | `{email, code, kdfSalt, authKey}` → `{ok}`，只修改密码，数据保留 |
| `POST /account-reset/request` | `{email}` → `{ok}`，发送重置账号验证码 |
| `POST /account-reset/complete` | `{email, code}` → `{ok}`，**永久删除**该账号的全部数据和设备，邮箱可以重新注册 |
| `POST /recovery/challenge` | `{email}` → `{accountId, nonce, expiresAt}` |

**账号内：**

| 方法与路径 | 会话 | 说明 |
| --- | --- | --- |
| `GET /account` | password 或 device | `{accountId, email, initialized, rootPub?}` |
| `POST /account/setup` | password，且账号未初始化 | 首次初始化：创建 root 和第一台管理设备，见 3.2.1 |
| `PUT /account/password` | device（管理设备） | `{kdfSalt, authKey}` |
| `POST /auth/challenge` | 请求头 `X-Harmonia-Account` | `{deviceId}` → `{nonce, expiresAt}`，nonce 只能使用一次，2 分钟内有效 |
| `POST /auth/device-session` | 请求头 `X-Harmonia-Account` | `{deviceId, nonce, signature}` → `{token, expiresAt}` |
| `POST /pairings` | password | `{name, platform, signPub, boxPub, rootPub}` → `{id, secret, expiresAt}`，10 分钟内有效 |
| `GET /pairings/{id}/status` | 请求头 `X-Harmonia-Account` 和 `X-Pairing-Secret` | `{status}`：`pending` / `approved` / `rejected` / `expired` |
| `GET /pairings` | device（管理设备） | 列出待处理的请求 |
| `POST /pairings/{id}/approve` | device（管理设备） | 见 3.3 |
| `POST /pairings/{id}/reject` | device（管理设备） | — |
| `GET /sync?since=N` | device | 见 3.4 |
| `GET /events` | device | WebSocket，见 3.5 |
| `POST /environments` | device（管理设备） | `{id, name, envelopes:[{recipient, keyVersion, sealed, sig}]}`，必须覆盖全部活跃的管理设备和 `recovery` |
| `PATCH /environments/{id}` | 管理设备或该环境的 admin | `{name}` |
| `DELETE /environments/{id}` | 管理设备或该环境的 admin | 删除环境和其中全部变量 |
| `PUT /environments/{id}/variables/{name}` | rw、admin 或管理设备 | `{value, keyVersion}`，请求头带 `Idempotency-Key` |
| `DELETE /environments/{id}/variables/{name}` | 同上 | 请求头带 `Idempotency-Key` |
| `PUT /devices/{id}/grants` | 管理设备 | `{grants:[{envId, role, expiresAt}], envelopes:[{envId, keyVersion, sealed, sig}]}`，整体替换；新授权的环境必须附带封装 |
| `PATCH /devices/{id}` | 管理设备 | `{name}` |
| `POST /devices/{id}/revoke` | 管理设备 | 撤销。不能撤销最后一台管理设备 |
| `POST /devices/self/revoke` | device | 本机退出。最后一台管理设备需要带上 `{confirmLast:true}` |
| `POST /recovery/session` | 请求头 `X-Harmonia-Account` | `{nonce, signature}` → `{token, expiresAt}` |
| `GET /recovery/material` | recovery | `{rootPub, generation, rootEnvelope:{sealed, sig}, environments:[{id, name, keyVersion}], envelopes:[{envId, keyVersion, sealed, sig}]}` |
| `POST /recovery/enroll` | recovery | `{device:{id, name, platform, signPub, boxPub, cert}, rootSealed, envelopes:[...]}`；新设备成为 `rotationRequired=true` 的管理设备，恢复会话随即作废 |
| `POST /recovery/rotate` | device（管理设备） | 见 3.6 |
| `GET /recovery/rotate/{key}` | device（管理设备） | `{state: "complete" \| "absent", generation?}` |

#### 3.2.1 首次初始化

```json
{
  "rootPub": "...",
  "device": {"id": "...", "name": "...", "platform": "android", "signPub": "...", "boxPub": "...", "cert": "..."},
  "rootSealed": "<封装给本设备的 root 种子>",
  "recovery": {"generation": "1", "signPub": "...", "boxPub": "...", "rootSealed": "...", "rootSig": "<恢复签名钥对 root-recovery 原文的签名>"}
}
```

### 3.3 批准配对

```json
{
  "kind": "client | manager",
  "cert": "<root 对设备证书的签名>",
  "grants": [{"envId": "...", "role": "ro|rw|admin", "expiresAt": 0}],
  "envelopes": [{"envId": "...", "keyVersion": "1", "sealed": "...", "sig": "..."}],
  "rootSealed": "<仅 manager：用新设备加密公钥封装的 root 种子>"
}
```

- 新设备的 ID 等于配对 ID。
- `kind=manager` 时不带 grants，envelopes 必须覆盖全部环境。
- `kind=client` 时，每条授权都必须带对应环境的封装。
- `expiresAt` 为 0 表示一直有效，直到被撤销。

### 3.4 同步

`GET /sync?since=N` 的响应：

```json
{
  "seq": 42,
  "self": {"id": "...", "kind": "client", "name": "...", "rotationRequired": false},
  "environments": [{"id": "...", "name": "...", "keyVersion": "1", "role": "rw", "expiresAt": 0}],
  "envelopes": [{"envId": "...", "keyVersion": "1", "sealed": "...", "sig": "..."}],
  "variables": [{"envId": "...", "name": "K", "value": "<密文>", "keyVersion": "1", "deleted": false, "seq": 40}],
  "manager": {
    "rootSealed": "...",
    "recovery": {"generation": "1", "boxPub": "..."},
    "devices": [{"id": "...", "name": "...", "platform": "...", "kind": "...", "signPub": "...", "boxPub": "...", "cert": "...", "createdAt": 0, "lastSeenAt": 0, "grants": [{"envId": "...", "role": "...", "expiresAt": 0}]}]
  }
}
```

- `environments` 和 `envelopes` 每次都返回当前可访问的**完整列表**。客户端据此清除不在列表中的环境。
- `variables` 只返回增量：所在环境可见，并且满足 `seq > N`，或者本设备对该环境的授权是在 N 之后获得的。
- `manager` 字段只返回给管理设备。管理设备的 `role` 恒为 `admin`。

### 3.5 推送

`GET /events` 升级为 WebSocket。服务端只推送提示，不推送任何数据：

- `{"type":"changed","seq":N}`：客户端收到后调用 `/sync`
- `{"type":"pairing"}`：只推送给管理设备
- `{"type":"revoked"}`：推送后服务端关闭连接

客户端每 30 秒发送一次文本 `ping`，服务端自动回复 `pong`。

### 3.6 轮换恢复码

```json
{
  "idempotencyKey": "...",
  "generation": "2",
  "signPub": "...", "boxPub": "...",
  "rootEnvelope": {"sealed": "...", "sig": "<新恢复签名钥对 root-recovery 原文的签名>"},
  "envelopes": [{"envId": "...", "keyVersion": "1", "sealed": "...", "sig": "<root 签名>"}],
  "password": {"kdfSalt": "...", "authKey": "..."}
}
```

- `generation` 必须等于当前值加 1；`envelopes` 必须覆盖全部环境。
- `password` 可选，恢复流程中用它设置新密码。
- 整个操作在一个事务中原子完成。成功后旧恢复码失效，发起设备的 `rotationRequired` 被清除。
- 用相同的 `idempotencyKey` 重试会返回原结果。

### 3.7 错误码

| code | HTTP | 含义 |
| --- | --- | --- |
| `invalid_request` | 400 | 字段缺失、格式不对或超出限制 |
| `unauthorized` | 401 | 未登录、会话过期、密码或签名错误 |
| `device_revoked` | 401 | 本设备已被撤销，客户端应清除本地数据 |
| `forbidden` | 403 | 权限不足，或授权已到期 |
| `rotation_required` | 403 | 需要先轮换恢复码 |
| `not_found` | 404 | 不存在 |
| `conflict` | 409 | 状态冲突，例如已初始化、配对已处理、幂等键对应的内容不同、代际不对 |
| `rate_limited` | 429 | 请求过于频繁 |
| `email_unverified` | 403 | 邮箱还没有验证 |
| `email_unavailable` | 503 | 服务器没有配置发信，无法发送验证码 |
| `internal` | 500 | 服务器内部错误 |

## 4. 规则摘要

- **权限**：ro 只读；rw 可写变量；admin 在 rw 之外可改名、删除环境；管理设备拥有全部权限，并且是唯一能批准设备、修改授权、撤销设备、轮换恢复码的角色。
- **写入**：同一变量按服务器接受顺序，后写覆盖先写。客户端不做乐观更新，以同步结果为准。
- **到期**：服务器拒绝已到期的授权；客户端离线时同样停用到期的环境。
- **撤销**：服务器删除该设备的授权、封装和会话，推送 `revoked`；客户端收到 `revoked` 推送或 `device_revoked` 错误后，清除本地全部数据。
- **限流**：注册、登录、找回密码、重置账号、恢复、配对、设备登录挑战按 IP 限制每分钟的请求次数；发送邮件另按账号限制重发间隔。
