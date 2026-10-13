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

全部使用 libsodium 兼容的标准构件。App 本机密钥保护另外使用 Android Keystore，iOS 上使用 Secure Enclave 和钥匙串，见 2.5。

| 用途 | 构件 |
| --- | --- |
| 变量值加密 | XChaCha20-Poly1305-IETF。密文 = b64(nonce24 ‖ ciphertext ‖ tag16)。AAD = `C(["harmonia.value", envId, keyVersion, name])` |
| 封装 | libsodium `crypto_box_seal`（X25519 + XSalsa20-Poly1305） |
| 加密密钥对 | 由 32 字节种子按 `crypto_box_seed_keypair` 派生：sk = SHA-512(seed)[0:32]，pk = X25519(sk, 基点) |
| 签名 | Ed25519，由 32 字节种子派生（`crypto_sign_seed_keypair`） |
| PIN 派生 | Argon2id（`crypto_pwhash` argon2id13，ops=3，mem=64 MiB，并行度 1），salt 16 字节，输出 32 字节。只用于 App 本机的 PIN 槽（2.5），不经过网络；账号没有密码 |
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

需要人工抄写或输入的码（恢复码、配对核对码、配对码、邮件验证码）统一使用 **Crockford Base32** 字母表 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`（不含 I、L、O、U），按 RFC 4648 的位序编码、无填充。解析时去掉 `-` 和空白，转为大写，把 `O` 视为 `0`、`I` 和 `L` 视为 `1`。

恢复码的显示格式：16 字节编码为 26 个字符，每 4 个字符用 `-` 分组。

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

- 每台设备在第一次接触账号时读取 `rootPub` 并保存在本地，此后不再接受变更：首次初始化时由本机生成；配对接入时从 `GET /accounts/lookup` 读取；恢复时由恢复码解开的 root 种子推出。
- 配对请求中包含设备钉住的 `rootPub`，并纳入配对指纹。管理设备在批准前检查它是否等于真实的 `rootPub`，不一致就拒绝（提示服务器可能被篡改）。
- 因此，服务器无法偷换封装：封装必须由 root 签名；也无法塞入假设备：设备证书必须由 root 签名。

### 2.4 配对指纹

```
fp = SHA-256(C(["harmonia.pairing", pairingId, signPub, boxPub, rootPub]))
核对码 = CrockfordBase32(fp[0:10])，16 个字符，按 4 个一组用 '-' 分隔
二维码内容 = "harmonia-pair:" + pairingId + ":" + b64(fp)
```

### 2.5 App 本机密钥保护

只用于 App 的本机存储，不经过网络，其他端不需要实现。除 2 节的构件外，这里额外使用系统中不可导出的密钥：Android 上是 Android Keystore，iOS 上是 Secure Enclave 和钥匙串。DEK、本机配置和 PIN 槽的格式两个平台相同，区别只在 `kek` 的算法和生物识别槽。

**Android：**

```
DEK  = 32 字节随机数，确定账号后设置 App PIN 时生成
本机配置 = XChaCha20-Poly1305(DEK, 配置 JSON, AAD = C(["harmonia.local", "config"]))

PIN 槽（必有）：
  pk   = Argon2id(PIN, salt)                  // salt 16 字节；参数同 2 节“PIN 派生”
  kek  = HMAC-SHA256(K_hw, pk)                // K_hw：Keystore HMAC 密钥，不可导出，不要求用户验证
  槽   = XChaCha20-Poly1305(kek, DEK, AAD = C(["harmonia.local-slot", "pin"]))

指纹槽（可选）：
  K_bio = Keystore AES-256-GCM 密钥：不可导出；每次使用都要求 Class 3 生物识别，
          通过 BiometricPrompt 的 CryptoObject 授权；新增或删除指纹即作废
  槽    = AES-256-GCM(K_bio, DEK)，IV 由 Keystore 生成，与密文一起保存
```

配置 JSON 中含设备签名种子和加密种子。缓存中的环境钥封装和变量值本来就是密文，不再加密。

规则：

- **解锁即解开 DEK。** 任意一个槽解开 DEK 就算验证通过。本机不保存 PIN 的哈希或其他可以离线核对 PIN 的值，PIN 是否正确只看 PIN 槽能否解开。
- **K_hw 必须参与每一次 PIN 尝试。** 先算 Argon2id，再调用 Keystore 算 HMAC。不能把 Keystore 用作外层加密：外层只要解开一次，就能拿到内层密文，然后在别的机器上暴力破解 PIN。
- **修改 PIN**：生成新的 salt，用新 PIN 重写 PIN 槽。DEK 和本机配置不变。
- **指纹槽作废**：Keystore 报告密钥永久失效时，删除指纹槽和 K_bio，只保留 PIN 槽。
- **清除**：退出登录、本机被撤销、选择“忘记 PIN”时，删除本机配置、两个槽、K_hw 和 K_bio。
- 以上密文仍然写入 `flutter_secure_storage`。

**iOS（v0.2.0）：**

```
PIN 槽（必有）：
  pk   = Argon2id(PIN, salt)                  // 同 Android
  P    = HashToP256(pk)                       // 见下
  kek  = SHA-256(ECDH(K_se, P))               // K_se：Secure Enclave 中的 P-256 私钥，不可导出，仅限本机，不要求用户验证；
                                              // ECDH 的结果取共享点的 x 坐标（32 字节）
  槽   = XChaCha20-Poly1305(kek, DEK, AAD = C(["harmonia.local-slot", "pin"]))

HashToP256(pk)：
  i 从 0 开始递增（1 字节）：x = SHA-256(pk ‖ i)
  取第一个能让 0x02 ‖ x 成为合法 P-256 压缩点的 i，P 就是这个点

面容 ID / 触控 ID 槽（可选）：
  DEK 保存为一条钥匙串条目：仅限本机，要求手机已设置锁屏密码；
  访问控制为“当前已录入的生物识别”（biometryCurrentSet），每次读取都由系统验证面容或指纹，不接受锁屏密码；
  新增或删除面容、指纹，或关闭锁屏密码后，系统使这条条目失效
```

- 上面“规则”中的各条同样适用，其中 K_hw 对应 K_se，K_bio 对应生物识别钥匙串条目，“Keystore 报告密钥永久失效”对应读取时系统报告条目不存在。
- **K_se 必须参与每一次 PIN 尝试。** Secure Enclave 只支持 P-256 的签名和密钥协商，没有 HMAC，所以用 ECDH 代替：P 由哈希得到，没有人知道它相对基点的离散对数，只凭 K_se 的公钥算不出 `K_se·P`，每试一个 PIN 都必须调用一次 Secure Enclave。这就是 2HashDH（RFC 9497 中 OPRF 所依据的伪随机函数）去掉盲化后的形式。K_se 的公钥不保存，也不使用。
- HashToP256 用逐次尝试而不是 RFC 9380 的映射，是为了只依赖系统库的压缩点解码。尝试次数会随 pk 变化，这不影响安全：pk 只在本机内存中出现，攻击者要得到 kek 仍然必须调用 Secure Enclave。P-256 的余因子为 1，曲线上的点都在素数阶群内，不需要另外检查子群。
- 钥匙串条目（`flutter_secure_storage` 写入的内容、K_se 的引用、生物识别条目）全部设为仅限本机，不同步到 iCloud 钥匙串，不随备份迁移到其他设备。
- **卸载后的残留**：iOS 的钥匙串在 App 卸载后不会清除。App 启动时如果数据目录中没有安装标记，先执行一次“清除”，再写入标记。
- **模拟器**：模拟器没有 Secure Enclave，仅在模拟器构建中把 K_se 换成保存在钥匙串里的普通 P-256 私钥；真机构建不包含这条路径。

## 3. HTTP API

- 基础路径为 `/api/v1`。请求和响应都是 JSON，只允许 HTTPS（本地开发时允许 `http://localhost`、`http://127.0.0.1`）。
- 错误响应：`{"error": "<code>", "message": "<中文说明>"}`。被限流时另带 `retryAfter`（秒），并设置 `Retry-After` 响应头。
- 根路径 `GET /`（以及 `HEAD /`）不属于 API，返回给浏览器看的实例首页（HTML），内容见设计文档 5.5。它同样只允许 HTTPS、受入口总量限制，不访问任何账号数据。首页上有服务器地址的二维码，内容就是地址本身（例如 `https://vault.example.com`，没有末尾的 `/`）；App 的“连接服务器”页扫它来填地址，只接受以 `https://` 开头（本地开发时也接受 `http://`）的内容。

### 3.0 账号与寻址

- 一个实例可以有多个相互隔离的账号，账号以**邮箱**标识。服务端为每个账号使用一个独立的 Durable Object，另有一个目录 Durable Object 负责“邮箱 → 账号 ID”的映射和注册策略。
- 注册策略由两个部署变量控制：
  - `ALLOW_REGISTRATION`：为 `false` 时只允许注册第一个账号。
  - `REQUIRE_EMAIL_VERIFICATION`：为 `true` 时注册需要验证邮箱（默认 `false`）。
- 账号状态：
  - `pending`：邮箱未验证。15 分钟内不验证，该注册作废，可以重新注册。
  - `active`：邮箱已验证（或不需要验证），可以用注册会话完成初始化。这时账号还没有任何数据，同一邮箱可以重新注册，按新注册处理。
  - `initialized`：已在手机上完成密钥初始化，账号公钥 `rootPub` 确定。之后不能再注册这个邮箱，新设备只能通过配对或恢复接入。
- 账号没有密码。
- 寻址方式：
  - 会话令牌的格式为 `<accountId>.<随机串>`，服务端据此定位账号。
  - 不带令牌的账号内请求（设备登录、发起配对、配对状态查询、恢复登录），在请求头 `X-Harmonia-Account` 中给出账号 ID。
  - 以邮箱为入口的请求（注册、查询账号、重置账号、开始恢复），由目录解析邮箱。
- 邮件验证码：8 位，字符取自 Crockford Base32 字母表（见 2.1），不区分大小写；15 分钟内有效。用途只有注册验证和重置账号。
  - 每次发送验证码，服务端同时返回流程凭证 `flow`（32 字节随机数，b64），验证码与它绑定，校验时必须带上 `flow`。
  - 每个 `flow` 最多尝试 5 次，失败只作废这个 `flow`，不影响别人申请的验证码。
  - 发信频率和数量见 3.8。

### 3.1 会话

| 类型 | 获取方式 | 有效期 | 允许的操作 |
| --- | --- | --- | --- |
| registration | `POST /register`（不需要验证邮箱时）或 `POST /register/verify` | 15 分钟 | 查看账号信息、首次初始化密钥 |
| device | `POST /auth/device-session` | 1 小时 | 按设备当前的权限 |
| recovery | `POST /recovery/session` | 15 分钟 | 读取恢复材料、登记本机 |

发起配对不需要会话，见 `POST /pairings`。

`rotationRequired=true` 的管理设备只允许调用：`/sync`、`/events`、`/account`、`/recovery/rotate*`、`/devices/self/revoke`。

### 3.2 端点

**以邮箱为入口（由目录解析）：**

| 方法与路径 | 说明 |
| --- | --- |
| `GET /instance` | `{product:"harmonia", version, protocol:1, registration:{open, first, emailVerification}}`。`open` 表示现在可以注册（开放注册，或者还没有任何账号）；`first` 表示还没有任何账号完成注册，客户端据此提示“创建第一个账号” |
| `POST /register` | `{email}` → 需要验证邮箱时 `{accountId, verificationRequired:true, flow}`，否则 `{accountId, verificationRequired:false, token, expiresAt}`（注册会话）。邮箱已注册且账号已初始化时返回 `conflict`；已注册但未初始化时按新注册处理（原来的注册会话作废）；注册未开放时返回 `forbidden` |
| `POST /register/verify` | `{email, flow, code}` → `{accountId, token, expiresAt}`（注册会话） |
| `POST /register/resend` | `{email}` → `{flow}` |
| `GET /accounts/lookup?email=` | 匿名查询：`{accountId, initialized, rootPub?}`（已初始化时带 `rootPub`）。邮箱没有注册时返回 `not_found`。服务器谎报 `rootPub` 时配对指纹不一致，管理设备批准前会发现 |
| `POST /account-reset/request` | `{email}` → `{flow}`，发送重置账号验证码 |
| `POST /account-reset/complete` | `{email, flow, code}` → `{ok}`，**永久删除**该账号的全部数据和设备，邮箱可以重新注册 |
| `POST /recovery/challenge` | `{email}` → `{accountId, nonce, expiresAt}` |

**账号内：**

| 方法与路径 | 会话 | 说明 |
| --- | --- | --- |
| `GET /account` | registration 或 device | `{accountId, email, initialized, rootPub?}` |
| `POST /account/setup` | registration，且账号未初始化 | 首次初始化：创建 root 和第一台管理设备，见 3.2.1。成功后注册会话作废 |
| `POST /auth/challenge` | 请求头 `X-Harmonia-Account` | `{deviceId}` → `{nonce, expiresAt}`，nonce 只能使用一次，2 分钟内有效 |
| `POST /auth/device-session` | 请求头 `X-Harmonia-Account` | `{deviceId, nonce, signature}` → `{token, expiresAt}` |
| `POST /pairing-codes` | device（管理设备） | `{}` → `{code, expiresAt}`：生成配对码，8 位 Crockford Base32，5 分钟内有效。每个账号同时只有一个有效配对码，重新生成会作废上一个；用它成功创建一个配对请求后即作废。服务端只保存 `SHA-256` 哈希 |
| `POST /pairings` | 请求头 `X-Harmonia-Account`，不需要会话 | `{name, platform, signPub, boxPub, rootPub, canManage, code?}` → `{id, secret, expiresAt, authorized}`，5 分钟内有效。`platform` 是 `android`、`ios`、`darwin`、`linux`、`windows` 之一，只用于显示。`canManage` 表示发起方的客户端具备管理功能（目前只有 App 为 true）。`code` 是配对码（解析规则同 2.1，可以带 `-` 和空白）：省略或为空时是匿名请求；给出时必须有效，否则返回 `unauthorized` 并计入 3.8 的递增等待，有效时请求的 `authorized` 为 true。`rootPub` 与账号不一致时返回 `conflict`。服务端记录发起方 IP；该 IP 被阻止时返回 `pairing_blocked` |
| `GET /pairings/{id}/events` | 请求头 `X-Harmonia-Account` 和 `X-Pairing-Secret` | 发起方的等待连接（WebSocket），见 3.5.1 |
| `GET /pairings/{id}/status` | 请求头 `X-Harmonia-Account` 和 `X-Pairing-Secret` | `{status}`：`pending` / `approved` / `rejected` / `expired` / `cancelled`。只在等待连接意外断开后查询一次 |
| `GET /pairings` | device（管理设备） | 列出发起方仍在等待的全部请求（包括匿名请求），每项带 `ip`、`canManage` 和 `authorized`（是否由配对码创建）。客户端的待批准列表、角标和自动弹出只处理 `authorized` 为 true 的请求；手输核对码时在全部请求中匹配 |
| `GET /pairings/{id}` | device（管理设备） | 单个请求（扫码时用二维码中的 ID 获取，匿名请求同样可以）；发起方已离开或请求已处理时返回 `conflict` |
| `POST /pairings/{id}/approve` | device（管理设备） | 见 3.3；发起方已离开时返回 `conflict` |
| `POST /pairings/{id}/reject` | device（管理设备） | `{block?: bool}`；`block` 为 true 时，30 分钟内拒绝来自该请求 IP 的新配对请求 |
| `GET /sync?since=N` | device | 见 3.4 |
| `GET /events` | device | WebSocket，见 3.5 |
| `POST /environments` | device（管理设备） | `{id, name, envelopes:[{recipient, keyVersion, sealed, sig}]}`，必须覆盖全部活跃的管理设备和 `recovery` |
| `PATCH /environments/{id}` | 管理设备或该环境的 admin | `{name}` |
| `DELETE /environments/{id}` | 管理设备或该环境的 admin | 删除环境和其中全部变量 |
| `PUT /environments/{id}/variables/{name}` | rw、admin 或管理设备 | `{value, keyVersion}`，请求头带 `Idempotency-Key` |
| `DELETE /environments/{id}/variables/{name}` | 同上 | 请求头带 `Idempotency-Key` |
| `PUT /devices/{id}/grants` | 管理设备 | `{grants:[{envId, role, expiresAt}], envelopes:[{envId, keyVersion, sealed, sig}]}`，整体替换；新授权的环境必须附带封装。已有授权保留激活状态和顺序，新授权默认激活并排在最后 |
| `PUT /devices/{id}/activation` | 管理设备；或设备本身，此时 `{id}` 为 `self` | `{envs:[{envId, active}]}`，按顺序从前到后排列（排在前面的覆盖后面的同名变量），必须包含该设备全部未到期的授权环境（可以带上已到期的），不能有未授权的环境，否则返回 `conflict`；没有列出的已到期授权保持原有相对顺序，排在后面。只修改激活状态和顺序 |
| `PATCH /devices/{id}` | 管理设备；或设备本身，此时 `{id}` 为 `self` | `{name, systemVars}`，两项都可以省略，但至少要有一项。`systemVars`（布尔）表示这台设备是否把系统自身使用的变量名写入系统环境，目前只有 Windows 上的 CLI 使用，默认 false。设备本身只能修改 `systemVars` |
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
- `kind=manager` 只能用于 `canManage=true` 的请求，否则返回 `invalid_request`。管理设备不限平台，取决于客户端是否具备管理功能。
- `kind=manager` 时不带 grants，envelopes 必须覆盖全部环境。
- `kind=client` 时，每条授权都必须带对应环境的封装。
- `expiresAt` 为 0 表示一直有效，直到被撤销。

### 3.4 同步

`GET /sync?since=N` 的响应：

```json
{
  "seq": 42,
  "self": {"id": "...", "kind": "client", "name": "...", "rotationRequired": false, "systemVars": false},
  "environments": [{"id": "...", "name": "...", "keyVersion": "1", "role": "rw", "expiresAt": 0, "active": true, "position": 0}],
  "envelopes": [{"envId": "...", "keyVersion": "1", "sealed": "...", "sig": "..."}],
  "variables": [{"envId": "...", "name": "K", "value": "<密文>", "keyVersion": "1", "deleted": false, "seq": 40}],
  "manager": {
    "rootSealed": "...",
    "recovery": {"generation": "1", "boxPub": "..."},
    "devices": [{"id": "...", "name": "...", "platform": "...", "kind": "...", "signPub": "...", "boxPub": "...", "cert": "...", "createdAt": 0, "lastSeenAt": 0, "systemVars": false, "grants": [{"envId": "...", "role": "...", "expiresAt": 0, "active": true, "position": 0}]}]
  }
}
```

- `environments` 和 `envelopes` 每次都返回当前可访问的**完整列表**。客户端据此清除不在列表中的环境。
- `variables` 只返回增量：所在环境可见，并且满足 `seq > N`，或者本设备对该环境的授权是在 N 之后获得的。
- `manager` 字段只返回给管理设备。管理设备的 `role` 恒为 `admin`。
- `systemVars` 是设备上的“写入系统变量”开关，见 `PATCH /devices/{id}`；响应里没有这个字段时（较旧的服务端）按 false 处理。
- `active` 和 `position` 是授权上的激活状态和顺序，`position` 从 0 开始，越小越靠前。管理设备的 `environments` 中 `active` 恒为 true，`position` 按环境创建先后排列。

### 3.5 推送

`GET /events` 升级为 WebSocket。服务端只推送提示，不推送任何数据：

- `{"type":"changed","seq":N}`：客户端收到后调用 `/sync`
- `{"type":"pairing"}`：只推送给管理设备，表示待批准列表有变化。匿名配对请求自身的变化不推送，见 3.5.1
- `{"type":"revoked"}`：推送后服务端关闭连接

客户端每 30 秒发送一次文本 `ping`，服务端自动回复 `pong`。

#### 3.5.1 配对等待连接

发起方创建配对请求后立即连接 `GET /pairings/{id}/events`，连接存在即表示“仍在等待”：

- 每个请求同时只允许一条等待连接。连接建立后，若请求由配对码创建（`authorized`），服务端向管理设备推送 `{"type":"pairing"}`；匿名请求不推送。没有等待连接的请求不会出现在 `GET /pairings` 中，也不能被批准。
- 服务端在请求被处理后向发起方推送 `{"type":"approved"}`、`{"type":"rejected"}` 或 `{"type":"expired"}`，然后关闭连接。
- 发起方每 10 秒发送一次 `ping`。服务端发现 25 秒内没有收到 `ping`，或连接断开时，若请求仍是 `pending`，就把它标记为 `cancelled`；由配对码创建的请求同时向管理设备推送 `{"type":"pairing"}`。
- 等待连接意外断开时，发起方查询一次 `GET /pairings/{id}/status`：`approved` 则继续完成接入，否则提示用户重新发起。
- 请求被管理设备批准或拒绝时，服务端向管理设备推送 `{"type":"pairing"}`；由配对码创建的请求被取消或过期时同样推送，匿名请求不推送。

### 3.6 轮换恢复码

```json
{
  "idempotencyKey": "...",
  "generation": "2",
  "signPub": "...", "boxPub": "...",
  "rootEnvelope": {"sealed": "...", "sig": "<新恢复签名钥对 root-recovery 原文的签名>"},
  "envelopes": [{"envId": "...", "keyVersion": "1", "sealed": "...", "sig": "<root 签名>"}]
}
```

- `generation` 必须等于当前值加 1；`envelopes` 必须覆盖全部环境。
- 整个操作在一个事务中原子完成。成功后旧恢复码失效，发起设备的 `rotationRequired` 被清除。
- 用相同的 `idempotencyKey` 重试会返回原结果。

### 3.7 错误码

| code | HTTP | 含义 |
| --- | --- | --- |
| `invalid_request` | 400 | 字段缺失、格式不对或超出限制 |
| `unauthorized` | 401 | 未登录、会话过期、签名错误，或配对码不对、已过期 |
| `device_revoked` | 401 | 本设备已被撤销，客户端应清除本地数据 |
| `forbidden` | 403 | 权限不足，或授权已到期 |
| `rotation_required` | 403 | 需要先轮换恢复码 |
| `not_found` | 404 | 不存在 |
| `conflict` | 409 | 状态冲突，例如邮箱已注册并初始化、配对已处理、幂等键对应的内容不同、代际不对 |
| `rate_limited` | 429 | 请求过于频繁 |
| `pairing_blocked` | 429 | 这个 IP 发起的配对请求刚被拒绝并阻止，30 分钟内不能再发起 |
| `email_unverified` | 403 | 邮箱还没有验证 |
| `email_unavailable` | 503 | 服务器没有配置发信，无法发送验证码 |
| `internal` | 500 | 服务器内部错误 |

### 3.8 限流与风控

原则：按网络分开计数，攻击者的失败只算在他自己的网络上；不因失败次数锁定账号或作废配对码；靠签名验证的操作不受匿名请求影响。

**网络**

- 计数单位“网络”：IPv4 按单个地址；IPv6 按 /64。
- 服务端只保存网络标识的 HMAC，密钥由每个账号和目录各自随机生成。原始 IP 只出现在配对请求和配对阻止记录中，随它们过期删除。

**入口**

- 每个网络每分钟最多 300 个请求（全部接口合计），在进入 Durable Object 之前拦截。
- 以邮箱为入口的接口（包括 `GET /accounts/lookup`）、设备登录挑战、恢复、发起配对，另按网络限制每分钟次数（注册、恢复挑战、发起配对 10 次，其他 20 至 30 次）。

**配对码**

- 输错次数按“账号 + 网络”计数，窗口 15 分钟；用配对码成功创建请求后清零该网络的计数。
- 每个网络前 5 次输错不受限制；之后每输错一次，该网络下次可以尝试的等待时间翻倍，从 5 秒起，最长 5 分钟。等待期间不校验配对码，直接返回 `rate_limited`。只影响这一个网络。
- 不做“输错 N 次作废配对码”，不做账号级锁定。被挡住的合法用户可以等待提示的时间后重试，或不带配对码改用扫码方式。

**邮件**

- 额度按账号计算，按 1 小时滚动：注册验证和重置账号共用，每个网络 2 封，合计 6 封；每天合计 20 封。
- 同一网络的重发间隔不少于 60 秒；同一网络、同一用途只保留最新一个 `flow`，不同网络的 `flow` 互不影响。
- 超出额度后不再发送新邮件，返回 `rate_limited`；已经发出的验证码在 15 分钟内照常有效。
- 注册验证邮件发往尚未注册的邮箱，另由目录限制：每个网络每小时 3 封，整个实例每天 100 封。

**配对**

- 每个网络同时最多 2 个等待中的请求（只计保持等待连接的请求，匿名和配对码创建的都算）。
- 整个账号同时最多 20 个匿名请求、5 个由配对码创建的请求，两者分开计数：匿名请求被占满时，用配对码仍然可以发起。
- 拒绝并阻止见 3.2。

**签名验证的操作**

- 设备登录挑战、设备会话、恢复会话只按网络限制每分钟次数，不设账号级计数。已接入设备的操作不受配对码和邮件限制的影响。

## 4. 规则摘要

- **权限**：ro 只读；rw 可写变量；admin 在 rw 之外可改名、删除环境；管理设备拥有全部权限，并且是唯一能批准设备、修改授权、撤销设备、轮换恢复码的角色。
- **写入**：同一变量按服务器接受顺序，后写覆盖先写。客户端不做乐观更新，以同步结果为准。
- **到期**：服务器拒绝已到期的授权；客户端离线时同样停用到期的环境。
- **激活**：激活状态和顺序只决定设备把哪些环境写入本机环境变量、同名变量由哪个环境提供，不是安全边界；设备能读取什么只由授权决定。新授权默认激活并排在最后。
- **撤销**：服务器删除该设备的授权、封装和会话，推送 `revoked`；客户端收到 `revoked` 推送或 `device_revoked` 错误后，清除本地全部数据。
- **限流与风控**：按网络和来源分开计数，不锁定账号，见 3.8。
- **配对**：知道邮箱就能创建匿名配对请求，但只有扫码或手输核对码的管理设备能取到它；配对码只让请求出现在管理设备上，不代替指纹核对。
