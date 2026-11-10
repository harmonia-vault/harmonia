# Harmonia 协议

本文是服务端、CLI、App 三端共同遵守的合同。改动本文需先经用户确认（见 AGENTS.md）。设计背景见 [rewrite-plan.md](rewrite-plan.md)。

## 1. 编码约定

| 项 | 规则 |
| --- | --- |
| 二进制 | base64url，无填充（下文记作 b64） |
| ID | 16 字节随机数的 b64，22 个字符，匹配 `^[A-Za-z0-9_-]{22}$` |
| 变量名 | `^[A-Za-z_][A-Za-z0-9_]{0,127}$`，不能以 `__HARMONIA_` 开头（不区分大小写） |
| 变量值 | UTF-8，最长 65536 字节，可以为空 |
| 变量备注 | UTF-8，去除首尾空白后最长 200 个字符，可以换行，可以为空 |
| 变量库名、环境名、设备名 | 去除首尾空白后 1–64 个字符 |
| 时间 | Unix 毫秒整数 |
| 规范数组 | 字符串数组的紧凑 JSON 的 UTF-8 字节，记作 `C([...])`。数组元素只允许 ASCII 可打印字符（ID、b64、十进制数字、固定单词），因此 Go、Dart、JS 的输出一致 |

## 2. 密码学

全部使用 libsodium 兼容的标准构件。App 本机密钥保护另外使用 Android Keystore，iOS 上使用 Secure Enclave 和钥匙串；电脑上的管理身份用口令保护，都见 2.5。

| 用途 | 构件 |
| --- | --- |
| 变量加密 | XChaCha20-Poly1305-IETF，值和备注一起加密，明文见 2.6。密文 = b64(nonce24 ‖ ciphertext ‖ tag16)。AAD = `C(["harmonia.var", vaultId, keyVersion, name])` |
| 封装 | libsodium `crypto_box_seal`（X25519 + XSalsa20-Poly1305） |
| 加密密钥对 | 由 32 字节种子按 `crypto_box_seed_keypair` 派生：sk = SHA-512(seed)[0:32]，pk = X25519(sk, 基点) |
| 签名 | Ed25519，由 32 字节种子派生（`crypto_sign_seed_keypair`） |
| PIN 派生 | Argon2id（`crypto_pwhash` argon2id13，ops=3，mem=64 MiB，并行度 1），salt 16 字节，输出 32 字节。只用于 App 本机的 PIN 槽（2.5），不经过网络；账号没有密码 |
| 口令派生 | Argon2id（`crypto_pwhash` argon2id13，ops=3，mem=256 MiB，并行度 1），salt 16 字节，输出 32 字节。只用于电脑上管理身份的口令槽（2.5），不经过网络 |
| 派生 | HKDF-SHA256，salt 为空，输出 32 字节 |
| 摘要 | SHA-256 |

### 2.1 密钥

| 密钥 | 生成 | 持有者 |
| --- | --- | --- |
| 账号根签名钥（root） | 32 字节随机种子 → Ed25519 | 全部管理设备；另封装给恢复钥。`rootPub` 公开 |
| 设备签名钥 | 32 字节随机种子 → Ed25519 | 设备自己 |
| 设备加密钥 | 32 字节随机种子 → box 密钥对 | 设备自己 |
| 库钥 | 32 字节随机数，每个变量库一把（2026-11-09 由“环境钥”改名） | 管理设备、恢复钥，以及对引用它的环境开启了“允许本机解密”的设备（都是封装形式） |
| 临时密钥对 | 每个批准请求在 CLI 内存中生成的 box 密钥对（32 字节随机种子），用完即丢 | 发起请求的 CLI 进程 |
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
| 封装签名 | `C(["harmonia.envelope", vaultId, keyVersion, recipient, b64(SHA-256(sealed))])` | root | 接收方：使用库钥之前必须验证 |
| 恢复根封装签名 | `C(["harmonia.root-recovery", generation, b64(SHA-256(sealed))])` | 恢复签名钥 | 恢复中的设备 |
| 设备登录 | `C(["harmonia.auth", deviceId, nonce])` | 设备签名钥 | 服务端 |
| 恢复登录 | `C(["harmonia.recovery-auth", nonce])` | 恢复签名钥 | 服务端 |
| 批准请求 | `C(["harmonia.approval-request", requestId, deviceId, b64(SHA-256(detail)), b64(SHA-256(payload))])` | 设备签名钥 | 管理设备：处理请求之前必须验证（3.9） |
| 批准结果 | `C(["harmonia.approval-grant", requestId, b64(SHA-256(sealed))])` | root | 发起请求的 CLI：解开结果之前必须验证（3.9） |

`detail`、`payload` 是请求中这两个字符串字段的 UTF-8 字节，没有 `payload` 时按空字符串计算；签名覆盖原样的字节，不重新序列化。`kind` 取 `manager` 或 `client`；`recipient` 为设备 ID 或字面量 `recovery`；`keyVersion`、`generation` 为十进制字符串。

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

### 2.5 本机密钥保护

**App：** 只用于 App 的本机存储，不经过网络，其他端不需要实现。除 2 节的构件外，这里额外使用系统中不可导出的密钥：Android 上是 Android Keystore，iOS 上是 Secure Enclave 和钥匙串。DEK、本机配置和 PIN 槽的格式两个平台相同，区别只在 `kek` 的算法和生物识别槽。

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

配置 JSON 中含设备签名种子和加密种子。缓存中的库钥封装和变量值本来就是密文，不再加密。

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

**电脑上的管理身份（设计文档第 16 节）：**

只用于 CLI 的管理身份，保存为数据目录下的 `manager.json`。结构与 App 相同，但没有硬件参与，也没有生物识别槽。日常身份的 `keys.json` 不变。

```
DEK  = 32 字节随机数，设置管理口令时生成
管理配置 = XChaCha20-Poly1305(DEK, 配置 JSON, AAD = C(["harmonia.local", "manager"]))

口令槽：
  kek  = Argon2id(口令, salt)                 // 口令取 UTF-8 字节；salt 16 字节；参数同 2 节“口令派生”
  槽   = XChaCha20-Poly1305(kek, DEK, AAD = C(["harmonia.local-slot", "passphrase"]))
```

- 配置 JSON 中含管理身份的设备签名种子和加密种子。root 种子不保存，每次从同步结果的 `manager.rootSealed` 解开并与钉住的 `rootPub` 核对。
- 管理身份与日常身份各自独立，所以 `manager.json` 自己记录服务器地址、账号 ID、邮箱和钉住的 `rootPub`。除此之外的明文只有设备 ID、设备名（用于提示用户在手机上移除哪台设备）、salt、口令槽和管理配置密文。
- 口令是否正确只看口令槽能否解开，不保存口令的哈希。
- **修改口令**：生成新的 salt，用新口令重写口令槽。DEK 和管理配置不变。
- **清除**：退出管理登录、被撤销、卸载时删除 `manager.json`。
- 文件权限和写入方式与数据目录下的其他文件相同。

### 2.6 变量明文

变量的明文是一个 UTF-8 编码的 JSON 对象，最长 512 KiB：

```json
{"value": "sk-...", "note": "测试用的 Key"}
```

- `value`：字符串，必填，变量值（第 1 节）。
- `note`：字符串，可选，变量备注（第 1 节）；没有备注时省略或为空字符串。
- 以后新增的字段都是可选的。读取时忽略不认识的字段；改写一个变量时，不认识的字段原样保留，只改自己认识的字段，这样旧客户端修改备注不会丢掉新版本加入的内容。
- 解密后不是 JSON 对象、缺少 `value`，或 `value`、`note` 不是字符串时，按解密失败处理。

## 3. HTTP API

- 基础路径为 `/api/v1`。请求和响应都是 JSON，只允许 HTTPS（本地开发时允许 `http://localhost`、`http://127.0.0.1`）。
- 错误响应：`{"error": "<code>", "message": "<中文说明>"}`。被限流时另带 `retryAfter`（秒），并设置 `Retry-After` 响应头。
- 写请求的重试（2026-10-15 增加）：带 `Idempotency-Key` 的写请求遇到网络错误、5xx 或 `rate_limited` 时，客户端只在短时间内（约 10 秒）用**同一个** `Idempotency-Key` 重试，服务端按幂等键返回原结果，不会重复写入；超过时间仍失败就报错，不在本机排队稍后重放（重放可能覆盖其他设备在这期间的修改）。
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
- 客户端版本：App 和 CLI 在每个请求上带请求头 `X-Harmonia-Version`，值是自身的版本号（如 `0.4.5`、`0.4.5-rc.1`），最多 32 个字符，只含字母、数字和 `.`、`-`、`+`。服务端在 `GET /sync` 时把它记到这台设备上，只用于在管理设备上显示，不参与任何权限判断；没有这个请求头或格式不对时忽略，保留上一次记录的值。
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
| `GET /instance` | `{product:"harmonia", version, protocol:1, registration:{open, first, emailVerification}, push}`。`push`（布尔，2026-11-09 增加）表示这台服务器是否开启后台通知（3.10）。`open` 表示现在可以注册（开放注册，或者还没有任何账号）；`first` 表示还没有任何账号完成注册，客户端据此提示“创建第一个账号” |
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
| `POST /pairing-codes` | device（管理设备） | `{minutes?}` → `{code, expiresAt}`：生成配对码，8 位 Crockford Base32。`minutes` 是有效期（分钟），5 到 60 的整数，省略时为 10，超出范围返回 `invalid_request`。每个配对码在过期前、或用它成功创建一个配对请求之前一直有效，生成新的不影响已有的；每个账号同时最多 10 个，超出时作废最早生成的那个。服务端只保存 `SHA-256` 哈希 |
| `POST /pairings` | 请求头 `X-Harmonia-Account`，不需要会话 | `{name, platform, signPub, boxPub, rootPub, canManage, code?}` → `{id, secret, expiresAt, authorized}`，5 分钟内有效。`platform` 是 `android`、`ios`、`darwin`、`linux`、`windows` 之一，只用于显示。`canManage` 表示发起方的客户端具备管理功能（App，以及电脑接入管理身份时为 true）。`code` 是配对码（解析规则同 2.1，可以带 `-` 和空白）：省略或为空时是匿名请求；给出时必须有效，否则返回 `unauthorized` 并计入 3.8 的递增等待，有效时请求的 `authorized` 为 true。`rootPub` 与账号不一致时返回 `conflict`。服务端记录发起方 IP；该 IP 被阻止时返回 `pairing_blocked` |
| `GET /pairings/{id}/events` | 请求头 `X-Harmonia-Account` 和 `X-Pairing-Secret` | 发起方的等待连接（WebSocket），见 3.5.1 |
| `GET /pairings/{id}/status` | 请求头 `X-Harmonia-Account` 和 `X-Pairing-Secret` | `{status}`：`pending` / `approved` / `rejected` / `expired` / `cancelled`。只在等待连接意外断开后查询一次 |
| `GET /pairings` | device（管理设备） | 列出发起方仍在等待的全部请求（包括匿名请求），每项带 `ip`、`canManage` 和 `authorized`（是否由配对码创建）。客户端的待批准列表、角标和自动弹出只处理 `authorized` 为 true 的请求；手输核对码时在全部请求中匹配 |
| `GET /pairings/{id}` | device（管理设备） | 单个请求（扫码时用二维码中的 ID 获取，匿名请求同样可以）；发起方已离开或请求已处理时返回 `conflict` |
| `POST /pairings/{id}/approve` | device（管理设备） | 见 3.3；发起方已离开时返回 `conflict` |
| `POST /pairings/{id}/reject` | device（管理设备） | `{block?: bool}`；`block` 为 true 时，30 分钟内拒绝来自该请求 IP 的新配对请求 |
| `GET /sync?since=N` | device | 见 3.4 |
| `GET /events` | device | WebSocket，见 3.5 |
| `POST /vaults` | device（管理设备） | `{id, name, envelopes:[{recipient, keyVersion, sealed, sig}]}`，必须覆盖全部活跃的管理设备和 `recovery`（2026-11-09 由 `POST /environments` 改名） |
| `PATCH /vaults/{id}` | device（管理设备） | `{name}` |
| `DELETE /vaults/{id}` | device（管理设备） | 删除变量库和其中全部变量，以及全部给它的封装。引用它的环境保留这条引用，标记为已失效（3.4 的 `missing`） |
| `PUT /vaults/{id}/variables/{name}` | 管理设备，或有写权限的设备（见下） | `{value, keyVersion}`，`value` 是值和备注一起加密的密文（第 2 节），只改备注也整体重写。请求头带 `Idempotency-Key` |
| `DELETE /vaults/{id}/variables/{name}` | 同上 | 请求头带 `Idempotency-Key` |
| `PATCH /vaults/{id}/variables` | 同上 | 批量写入（2026-10-15 增加）：`{keyVersion, set:[{name, value}], delete:[name]}`。`set` 与 `delete` 合计 1 到 100 项，同一个变量名只能出现一次；`value` 的格式同单个写入，`keyVersion` 对整批生效。整个请求在一个事务中完成：任意一项不合法、权限不足或 `keyVersion` 不是变量库当前的密钥版本时整体拒绝，什么都不写；成功后整批共用一个新的 `seq`，返回 `{seq}`，只推送一次 `changed`。删除不存在的变量不报错。请求头带 `Idempotency-Key`，请求体最大约 2 MB。导入、复制、多选删除和手机批准的写入用它，免得逐个调用撞上 3.8 的入口限流 |
| `POST /environments` | device（管理设备） | `{id, name, refs, envelopes}`，`refs` 的格式见下；最终名字有重复时返回 `conflict`，`message` 指出重复的名字。环境名与已有环境相同（去掉首尾空白后不区分大小写比较，2026-11-10）时同样返回 `conflict`。`envelopes` 新建时为空 |
| `PUT /environments/{id}` | device（管理设备） | `{name, refs, envelopes:[{recipient, vaultId, keyVersion, sealed, sig}]}`，整体替换，环境名的检查同上。新引用的变量库必须为每台对这个环境开启了 `localDecrypt` 且还没有这个变量库封装的设备附带封装，缺少时返回 `conflict`；不再被某台设备任何 `localDecrypt` 授权用到的变量库，服务端删除给它的封装。引用改变后推送 `changed` |
| `DELETE /environments/{id}` | device（管理设备） | 删除环境和对它的全部授权（同样清理不再用到的封装），变量库不受影响 |
| `PUT /devices/{id}/grants` | 管理设备 | `{grants:[{environmentId, role, expiresAt, localDecrypt}], envelopes:[{vaultId, keyVersion, sealed, sig}]}`，整体替换。`localDecrypt` 为 true 的授权，它引用到的每个变量库都必须有给这台设备的封装（已有的不用重复附带），否则返回 `conflict`；不再用到的封装由服务端删除。已有授权保留激活状态和顺序，新授权默认激活并排在最后 |
| `PUT /devices/{id}/activation` | 管理设备；或设备本身，此时 `{id}` 为 `self` | `{envs:[{environmentId, active}]}`，按顺序从前到后排列（排在前面的覆盖后面的同名变量），必须包含该设备全部未到期的授权环境（可以带上已到期的），不能有未授权的环境，否则返回 `conflict`；没有列出的已到期授权保持原有相对顺序，排在后面。只修改激活状态和顺序 |
| `PATCH /devices/{id}` | 管理设备；或设备本身，此时 `{id}` 为 `self` | `{name, systemVars, autoUpdate}`，各项都可以省略，但至少要有一项。`systemVars`（布尔）表示这台设备是否把系统自身使用的变量名写入系统环境，目前只有 Windows 上的 CLI 使用，默认 false。`autoUpdate`（布尔）表示这台设备的后台服务发现新版本时是否自动升级，只有 CLI 使用，默认 false。设备本身只能修改 `systemVars` 和 `autoUpdate` |
| `POST /devices/{id}/update` | 管理设备 | 无请求体 → `{}`。让这台设备的后台服务现在检查更新并升级（设计文档 5.11），服务端向它推送 `{"type":"update"}`。只能用于 `kind` 为 `client` 的设备，否则返回 `invalid_request`；这台设备当前没有推送连接时返回 `device_offline` |
| `POST /devices/{id}/revoke` | 管理设备 | 撤销。不能撤销最后一台管理设备 |
| `POST /devices/self/revoke` | device | 本机退出。最后一台管理设备需要带上 `{confirmLast:true}` |
| `PUT /devices/self/push` | device（管理设备） | `{handle}` → `{}`：登记或替换这台设备的推送句柄，见 3.10（2026-11-09） |
| `DELETE /devices/self/push` | device（管理设备） | 无请求体 → `{}`：删除这台设备的推送句柄，没有时也返回 `{}` |
| `POST /recovery/session` | 请求头 `X-Harmonia-Account` | `{nonce, signature}` → `{token, expiresAt}` |
| `GET /recovery/material` | recovery | `{rootPub, generation, rootEnvelope:{sealed, sig}, vaults:[{id, name, keyVersion}], envelopes:[{vaultId, keyVersion, sealed, sig}]}` |
| `POST /recovery/enroll` | recovery | `{device:{id, name, platform, signPub, boxPub, cert}, rootSealed, envelopes:[...]}`；新设备成为 `rotationRequired=true` 的管理设备，恢复会话随即作废 |
| `POST /recovery/rotate` | device（管理设备） | 见 3.6 |
| `GET /recovery/rotate/{key}` | device（管理设备） | `{state: "complete" \| "absent", generation?}` |
| `POST /approvals` | device（客户端设备） | 发起批准请求，见 3.9 |
| `GET /approvals/{id}/events` | device（发起请求的设备） | 发起方的等待连接（WebSocket），见 3.9 |
| `GET /approvals/{id}/status` | device（发起请求的设备） | `{status, result?}`，只在等待连接意外断开后查询一次 |
| `GET /approvals` | device（管理设备） | 列出发起方仍在等待的请求 |
| `POST /approvals/{id}/approve` | device（管理设备） | 见 3.9；发起方已离开时返回 `conflict` |
| `POST /approvals/{id}/reject` | device（管理设备） | 无请求体 → `{}` |
| `GET /authorizations` | device（管理设备，或设备本身） | 正在生效的授权（有效时长不是“仅这一次”的已批准请求）：`[{id, deviceId, items, scope, expiresAt}]`，见 3.9 |
| `POST /authorizations/{id}/end` | 管理设备，或设备本身 | 结束一项正在生效的授权，向那台设备推送 `{"type":"authorization-ended","id"}` |

**引用的格式**（2026-11-09）：

```json
{"vaultId": "...", "scope": "all | pick", "items": [{"name": "OPENAI_API_KEY", "as": "LLM_KEY"}]}
```

- `scope` 为 `pick` 时，`items` 列出勾选的变量，`as` 可选，是在环境里的名字；为 `all` 时包含变量库的全部变量，`items` 只列出要改名的那几个（`as` 必填）。`items` 里的 `name` 不需要在变量库中已经存在（变量可能稍后才写入），不存在的不提供变量。
- 同一个 `vaultId` 在一个环境中只能出现一次，`refs` 最多 50 条。
- **最终名字**：按 `refs` 的顺序展开，每个变量取 `as`（没有时取原名）。保存时只检查当时的最终名字；以后 `all` 引用的变量库新增了重复的名字，排在前面的引用优先，3.4 的 `items` 里只保留优先的那个，另在 `shadowed` 中列出被遮住的。
- 2026-11-10 去掉引用的 `writable` 字段（设计文档第 19 节），写权限只看授权的 `role`。
- **写权限**：客户端设备写入或删除 `/vaults/{id}/variables/{name}` 时，必须有一项未到期、`role` 为 `rw`、`localDecrypt` 为 true 的授权，其环境中有一条引用覆盖这个变量：`pick` 时 `name` 在 `items` 中，`all` 时任何变量都算（包括新增）。没有开启 `localDecrypt` 的设备通过 3.9 的写入请求由管理设备代为写入。

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
  "grants": [{"environmentId": "...", "role": "ro|rw", "expiresAt": 0, "localDecrypt": false}],
  "envelopes": [{"vaultId": "...", "keyVersion": "1", "sealed": "...", "sig": "..."}],
  "rootSealed": "<仅 manager：用新设备加密公钥封装的 root 种子>"
}
```

- 新设备的 ID 等于配对 ID。
- `kind=manager` 只能用于 `canManage=true` 的请求，否则返回 `invalid_request`。管理设备不限平台，取决于客户端是否具备管理功能。
- `kind=manager` 时不带 grants，envelopes 必须覆盖全部变量库。
- `kind=client` 时，`localDecrypt` 为 true 的授权引用到的每个变量库都必须带封装；其他授权不带封装。
- `expiresAt` 为 0 表示一直有效，直到被撤销。

### 3.4 同步

`GET /sync?since=N` 的响应：

```json
{
  "seq": 42,
  "full": false,
  "self": {"id": "...", "kind": "client", "name": "...", "rotationRequired": false, "systemVars": false, "autoUpdate": false},
  "environments": [{
    "id": "...", "name": "...", "role": "rw", "expiresAt": 0, "localDecrypt": false, "active": true, "position": 0,
    "items": [{"name": "LLM_KEY", "vaultId": "...", "source": "OPENAI_API_KEY"}],
    "shadowed": [{"name": "DB_URL", "vaultId": "...", "source": "DB_URL"}],
    "createVaults": ["..."]
  }],
  "vaultNames": [{"id": "...", "name": "..."}],
  "vaults": [{"id": "...", "keyVersion": "1"}],
  "envelopes": [{"vaultId": "...", "keyVersion": "1", "sealed": "...", "sig": "..."}],
  "variables": [{"vaultId": "...", "name": "OPENAI_API_KEY", "value": "<密文>", "keyVersion": "1", "deleted": false, "seq": 40}],
  "managers": [{"id": "...", "signPub": "...", "boxPub": "...", "cert": "..."}],
  "manager": {
    "rootSealed": "...",
    "recovery": {"generation": "1", "boxPub": "..."},
    "vaults": [{"id": "...", "name": "...", "keyVersion": "1"}],
    "environments": [{"id": "...", "name": "...", "refs": [{"vaultId": "...", "scope": "all", "items": [], "missing": false}]}],
    "devices": [{"id": "...", "name": "...", "platform": "...", "kind": "...", "signPub": "...", "boxPub": "...", "cert": "...", "createdAt": 0, "lastSeenAt": 0, "version": "0.4.5", "systemVars": false, "autoUpdate": false, "grants": [{"environmentId": "...", "role": "...", "expiresAt": 0, "localDecrypt": false, "active": true, "position": 0}]}]
  }
}
```

- `environments`、`vaults`、`envelopes` 和 `managers` 每次都返回**完整列表**。客户端据此清除不在列表中的环境和变量库。
- `environments` 是这台设备被授权的环境（管理设备为全部环境）。`items` 是服务端按 3.2 的引用规则展开的最终名字：`source` 是变量库里的原名；只列出变量库里当前存在的变量。`shadowed` 是被前面的引用遮住的同名变量。`createVaults` 是环境里 `scope` 为 `all` 的引用所指的变量库，`role` 为 `rw` 时可以在其中新增变量。
- `vaultNames` 是这台设备的环境所引用的全部变量库的 ID 和名字，供客户端显示来源、按名字指定写入的变量库（设计文档 17.2）；不含其中的变量。
- `vaults`、`envelopes`、`variables` 只涉及这台设备可以在本机解密的变量库：被某项未到期、`localDecrypt` 为 true 的授权引用到的变量库（管理设备为全部）。`variables` 只返回其中被这些授权的 `items` 覆盖的变量（管理设备为全部），并且只返回增量：满足 `seq > N` 的变化（包括删除墓碑）。设备能看到的变量范围在 N 之后变过（授权、`localDecrypt` 或环境的引用变化，变量库被删除）时，`full` 为 true，`variables` 改为返回范围内现存的全部变量，客户端用它整体替换缓存；`since=0` 时 `full` 恒为 true。没有开启 `localDecrypt` 的授权只在 `environments` 里出现变量名，不下发密文。
- `managers` 是全部活跃管理设备的公钥和证书，客户端设备用它们加密 3.9 的写入内容，使用前先用钉住的 `rootPub` 验证证书。
- `manager` 字段只返回给管理设备。管理设备的 `role` 恒为 `rw`，`localDecrypt` 恒为 true。`refs` 中的 `missing` 表示引用的变量库已被删除。
- `version` 是这台设备最近一次同步时上报的客户端版本（见第 3 节开头的 `X-Harmonia-Version`），由设备自己上报，服务端不校验真伪；设备还没有上报过时是空字符串，响应里没有这个字段时（较旧的服务端）同样按未知处理。
- `systemVars` 是设备上的“写入系统变量”开关，见 `PATCH /devices/{id}`；响应里没有这个字段时（较旧的服务端）按 false 处理。
- `autoUpdate` 是设备上的“自动更新”开关，见 `PATCH /devices/{id}`；没有这个字段时按 false 处理。
- 设备同步时上报的 `version` 与记录的不同时，服务端更新记录、`head_seq + 1`，并向管理设备推送 `changed`，让设备列表显示新版本。
- `active` 和 `position` 是授权上的激活状态和顺序，`position` 从 0 开始，越小越靠前。管理设备的 `environments` 中 `active` 恒为 true，`position` 按环境创建先后排列。

### 3.5 推送

`GET /events` 升级为 WebSocket。服务端只推送提示，不推送任何数据：

- `{"type":"changed","seq":N}`：客户端收到后调用 `/sync`
- `{"type":"pairing"}`：只推送给管理设备，表示待批准列表有变化。匿名配对请求自身的变化不推送，见 3.5.1
- `{"type":"revoked"}`：推送后服务端关闭连接
- `{"type":"approval"}`：只推送给管理设备，表示待批准的解密或写入请求有变化（3.9）
- `{"type":"authorization-ended","id":"..."}`：只推送给那台设备，表示一项正在生效的授权被结束，保管进程清除对应的变量（3.9）
- `{"type":"update"}`：只推送给被 `POST /devices/{id}/update` 指定的设备，表示现在检查更新并升级。不带版本号，客户端按自己的更新渠道检查，只安装签名有效且比当前版本新的安装包

客户端每 30 秒发送一次文本 `ping`，服务端自动回复 `pong`。

系统通知是否发送不依赖这条连接是否存在，见 3.10。

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
  "envelopes": [{"vaultId": "...", "keyVersion": "1", "sealed": "...", "sig": "<root 签名>"}]
}
```

- `generation` 必须等于当前值加 1；`envelopes` 必须覆盖全部变量库。
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
| `device_offline` | 409 | 目标设备现在没有连上服务器（例如电脑上没有运行后台服务、关机或断网） |
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
- 批量写入变量用 `PATCH /environments/{id}/variables`，一次最多 100 项，只算一个请求。
- 以邮箱为入口的接口（包括 `GET /accounts/lookup`）、设备登录挑战、恢复、发起配对，另按网络限制每分钟次数（注册、恢复挑战、发起配对 10 次，其他 20 至 30 次）。

**配对码**

- 输错次数按“账号 + 网络”计数，窗口 15 分钟；用配对码成功创建请求后清零该网络的计数。
- 每个网络前 5 次输错不受限制；之后每输错一次，该网络下次可以尝试的等待时间翻倍，从 5 秒起，最长 5 分钟。等待期间不校验配对码，直接返回 `rate_limited`。只影响这一个网络。
- 不做“输错 N 次作废配对码”，不做账号级锁定。被挡住的合法用户可以等待提示的时间后重试，或不带配对码改用扫码方式。

**邮件**

- 额度按账号计算，按 1 小时滚动：注册验证和重置账号共用，每个网络 2 封，合计 6 封；每天合计 20 封。
- 同一网络的重发间隔不少于 60 秒；同一网络、同一用途只保留最新一个 `flow`，不同网络的 `flow` 互不影响。
- 超出额度后不再发送新邮件，返回 `rate_limited`；已经发出的验证码在 15 分钟内照常有效。

**本地测试**（2026-11-09）

- 端到端测试的请求都来自同一个网络。只为本地测试启动服务端时设置变量 `DEV_RELAXED_LIMITS=true`，此时跳过“入口”一节中按网络的每分钟次数限制和邮件 60 秒重发间隔；入口总量、配对码的递增等待和邮件额度不变。与 `DEV_MAIL_LOG` 一样只用于本地，部署时不设置。
- 注册验证邮件发往尚未注册的邮箱，另由目录限制：每个网络每小时 3 封，整个实例每天 100 封。

**配对**

- 每个网络同时最多 2 个等待中的请求（只计保持等待连接的请求，匿名和配对码创建的都算）。
- 整个账号同时最多 20 个匿名请求、5 个由配对码创建的请求，两者分开计数：匿名请求被占满时，用配对码仍然可以发起。
- 拒绝并阻止见 3.2。

**批准请求**（2026-11-09）

- 每台设备同时最多 3 个等待中的批准请求，整个账号最多 20 个，超出时返回 `rate_limited`。

**签名验证的操作**

- 设备登录挑战、设备会话、恢复会话只按网络限制每分钟次数，不设账号级计数。已接入设备的操作不受配对码和邮件限制的影响。

### 3.9 批准解密与写入（2026-11-09）

没有开启 `localDecrypt` 的授权，变量值只能经管理设备批准取得或写入。设计和界面见设计文档第 17 节。

**发起：`POST /approvals`**

```json
{"id": "<客户端生成的 ID>", "detail": "<JSON 字符串>", "payload": "<JSON 字符串，只有写入请求有>", "sig": "<设备签名钥对批准请求原文的签名>"}
```

`detail` 解析后是：

```json
{
  "kind": "read | write",
  "deviceId": "...",
  "createdAt": 0,
  "ephPub": "<临时密钥对的公钥，只有读取请求有>",
  "command": "npm run dev",
  "cwd": "/home/me/blog",
  "items": [{"environmentId": "...", "name": "LLM_KEY", "vaultId": "<只在写入请求新增变量时有>"}],
  "delete": [{"environmentId": "...", "name": "OLD_KEY"}]
}
```

- `items` 用环境里的最终名字。读取请求列出要取的变量；写入请求列出要写入的变量，`delete` 列出要删除的变量（只有写入请求有）。两者合计 1 到 200 项。
- `command`、`cwd` 各最长 1000 个字符，只用于在管理设备上显示，客户端负责截断。`detail` 最长 64 KiB，`payload` 最长约 2 MB。
- 写入请求的 `payload` 解析后是 `{"sealed":[{"managerId", "sealed"}]}`：为 3.4 `managers` 中的每一台各加密一份，`sealed = crypto_box_seal(管理设备 boxPub, 写入内容)`。写入内容是 UTF-8 JSON：`{"requestId": "...", "set": [{"environmentId", "name", "vaultId", "plain": <2.6 的明文对象>}]}`，`vaultId` 与 `detail` 中的一致（新增变量时）或省略（修改已有变量时）。电脑上读不到原来的值，所以修改已有变量时 `plain` 可以只带要改的字段（例如只改 `note`），管理设备把它合并到原来的明文上再加密；新增变量时 `plain` 必须带 `value`。
- **请求码** = `CrockfordBase32(SHA-256(detail)[0:3])` 的前 4 个字符。客户端和管理设备都由 `detail` 自己算出并显示，供用户核对。
- 服务端检查：签名（用设备的 `signPub`）、`deviceId` 是当前会话的设备、`createdAt` 与服务器时间相差不超过 5 分钟、`id` 没有用过；`items` 和 `delete` 中的每一项所在的环境都授权给了这台设备、没有到期、`localDecrypt` 为 false，名字在 3.4 的 `items` 中；写入请求还要求 `role` 为 `rw`：新增的变量带 `vaultId`（设计文档 17.2：新增变量必须指定变量库，`environmentId` 是提供写权限的那个环境），它必须在这个环境的 `createVaults` 中，名字不能和变量库或环境里已有的名字重复。不满足时返回 `forbidden` 或 `invalid_request`。
- 成功返回 `{expiresAt}`，请求 2 分钟内有效。服务端向管理设备推送 `{"type":"approval"}`。

**等待**：发起后立即连接 `GET /approvals/{id}/events`，规则与 3.5.1 的配对等待连接相同：同时只允许一条连接；没有等待连接的请求不出现在 `GET /approvals` 中，也不能被批准；发起方每 10 秒发送一次 `ping`，25 秒没有收到或连接断开时，仍在等待的请求标记为 `cancelled`，并向管理设备推送 `approval`。处理后服务端推送 `{"type":"approved","result":{...}}`（读取请求带下面的结果，写入请求为 `{}`）、`{"type":"rejected"}` 或 `{"type":"expired"}`，然后关闭连接。连接意外断开时查询一次 `GET /approvals/{id}/status`，批准后的结果保留 2 分钟。

**批准：`POST /approvals/{id}/approve`**

- 管理设备先验证请求签名（设备证书由 root 签名），再按自己同步到的数据重新做一遍服务端的检查，任何一项不符就拒绝并提示服务器数据可能有误。
- **读取请求**：请求体 `{"sealed", "sig", "scope", "expiresAt"}`。`sealed = crypto_box_seal(ephPub, 结果)`，`sig` 是 root 对批准结果原文的签名。结果是 UTF-8 JSON：

  ```json
  {
    "requestId": "...",
    "scope": "once | terminal | all",
    "expiresAt": 0,
    "values": [{"environmentId": "...", "name": "LLM_KEY", "vaultId": "...", "source": "OPENAI_API_KEY", "plain": {"value": "...", "note": ""}}]
  }
  ```

  `scope` 为 `once` 时只用于这一次；`terminal` 只对发起请求的终端有效；`all` 对这台电脑上的所有程序有效。`expiresAt` 为到期时间，`0` 表示长期（`once` 时忽略）。请求体外层的 `scope`、`expiresAt` 与结果里的相同，只供服务端记录和显示；客户端只认结果里经过 root 签名的值。服务端批准时记下这些变量当时的版本（`seq`），变量被修改时结束授权并通知保管进程（见下）。
- **写入请求**：管理设备解开加密给自己的那一份，核对 `requestId` 和名字与 `detail` 一致，用库钥加密后调用 `PATCH /vaults/{id}/variables` 写入（删除同理），全部成功后再调用批准，请求体为 `{}`。
- 客户端收到结果后验证 root 签名、核对 `requestId`，再用临时私钥解开。

**正在生效的授权**：读取请求批准时 `scope` 不是 `once`，服务端记录一项授权 `{id, deviceId, items, scope, expiresAt}`（`id` 即请求 ID），只用于显示和结束：变量已经交给了电脑，有效期由电脑上的保管进程执行，服务端无法强制。以下情况服务端删除记录并向那台设备推送 `authorization-ended`：到期、`POST /authorizations/{id}/end`、设备被撤销、对应环境的授权被删除或到期或改为 `localDecrypt`、环境的引用改变、授权里的变量被修改或删除（按批准时记下的 `seq` 比较）。保管进程退出时尽力结束自己持有的授权；没能通知到的（例如断网时关机），CLI 下次同步时发现保管进程没有持有，就结束它。

**拒绝：`POST /approvals/{id}/reject`**，服务端向发起方推送 `rejected`。

### 3.10 后台通知（2026-11-09）

有新的批准请求或配对码请求时，服务端经推送中继（第 5 节）给管理设备发系统通知，不按 App 是否在前台或 `/events` 是否连接来筛选。App 在前台时不显示通知横幅，仍直接弹出批准页。设计见设计文档第 18 节。

**句柄**

- 32 字节随机数的 b64（43 个字符），由中继生成，App 通过 `PUT /devices/self/push` 交给服务端，每台设备最多一个，新的替换旧的。
- 句柄本身就是凭证：持有它就能让中继给那台手机发通知。服务端把它保存在 `devices.push_handle`，不出现在 `/sync`、`/devices` 等任何响应中。
- 格式不对时返回 `invalid_request`；这台服务器关闭了后台通知时返回 `forbidden`，`message` 为“这台服务器关闭了后台通知”。
- 设备被撤销、本机退出时，服务端删除句柄，并尽力向中继调用 `DELETE /registration`。

**什么时候发**

| 事件 | 时机 | `type` |
| --- | --- | --- |
| 批准请求 | 新的批准请求的等待连接建立时（3.9） | `approval` |
| 配对请求 | `authorized` 为 true 的配对请求的等待连接建立时（3.5.1）；匿名请求不发 | `pairing` |

- 发给：登记了句柄、状态为有效且 `rotationRequired` 为 false 的管理设备，包括此刻有 `/events` 连接的设备。
- 请求被批准、拒绝、取消、过期时不发，也不撤回已发的通知。
- 服务端在响应之后（`waitUntil`）对每台设备调用中继的 `POST /notify`，超时 10 秒，失败不重试。中继返回 `not_found` 时删除这个句柄；其他错误忽略。
- 部署变量 `PUSH_NOTIFICATIONS` 为 `false` 时不接受句柄、不联系中继，已保存的句柄不再使用；`GET /instance` 的 `push` 为 false。默认开启。
- 中继地址是服务端代码中的常量，和 App 中的一致。只用于本地开发的部署变量 `DEV_PUSH_RELAY_URL` 可以把它换成本地中继的地址，部署时不设置。

## 4. 规则摘要

- **权限**：客户端设备按环境授权，ro 只读，rw 可以修改、删除环境中的变量，并在 `createVaults` 的变量库里新增变量（2026-10-14 去掉 admin：客户端设备不能改名或删除环境；2026-11-10 去掉引用的 `writable`）。管理设备拥有全部权限，并且是唯一能新建、改名、删除变量库和环境，批准设备、修改授权、处理批准请求、撤销设备、轮换恢复码的角色。
- **两层**（2026-11-09）：变量存放在变量库中，环境只引用变量库，不能引用环境；设备只能被授权环境。
- **本机解密与批准**：授权的 `localDecrypt` 为 true 时设备持有库钥，在本机解密；为 false（默认）时设备不持有库钥，每次经管理设备批准取得变量（3.9）。
- **写入**：同一变量按服务器接受顺序，后写覆盖先写；批量写入整批生效或整批拒绝。客户端不做乐观更新，以同步结果为准。
- **到期**：服务器拒绝已到期的授权；客户端离线时同样停用到期的环境。
- **激活**：激活状态和顺序只决定设备把哪些环境写入本机环境变量、同名变量由哪个环境提供，不是安全边界；设备能读取什么只由授权决定。新授权默认激活并排在最后。
- **撤销**：服务器删除该设备的授权、封装和会话，推送 `revoked`；客户端收到 `revoked` 推送或 `device_revoked` 错误后，清除本地全部数据。
- **限流与风控**：按网络和来源分开计数，不锁定账号，见 3.8。
- **配对**：知道邮箱就能创建匿名配对请求，但只有扫码或手输核对码的管理设备能取到它；配对码只让请求出现在管理设备上，不代替指纹核对。
- **后台通知**（2026-11-09）：只是提醒，内容固定、不带任何数据；收不到不影响任何流程（3.10、第 5 节）。

## 5. 推送中继接口（2026-11-09）

推送中继是发布者部署的独立服务（代码在 `relay/`），持有 APNs 和 FCM 的凭据，替各个实例给手机发系统通知。设计见设计文档 18.5。

- 基础路径为 `https://harmonia-push.zzz.sd/api/v1`，只允许 HTTPS。这个地址是 App 和服务端代码中的常量，不能更换（设计文档 18.5）。请求、响应和错误格式同第 3 节，错误码沿用 3.7。
- 带句柄的请求在请求头 `Authorization: Bearer <句柄>` 中给出句柄，不放进路径或请求体。
- 中继只保存句柄的 SHA-256，不保存请求方 IP。
- **兼容**：各个实例和 App 不会同时升级，却共用同一个中继，所以本节的接口只做增量修改，已有的接口、字段和行为不改不删（设计文档 12.10，AGENTS.md 第 4 条的例外）。

### 5.1 端点

| 方法与路径 | 调用方 | 说明 |
| --- | --- | --- |
| `POST /registrations` | App | `{platform, token, apnsEnvironment?}` → `{handle}`。`platform` 为 `ios` 或 `android`；`token` 是 APNs 设备令牌（十六进制）或 FCM 注册令牌，最长 4096 个字符；`platform` 为 `ios` 时必须带 `apnsEnvironment`（`production` 或 `sandbox`）。每次调用都生成新句柄 |
| `PUT /registration` | App | `{token, apnsEnvironment?}` → `{}`：确认登记，更新令牌和最近确认时间，句柄不变。句柄不存在时返回 `not_found`，App 重新登记 |
| `DELETE /registration` | App 或实例 | 无请求体 → `{}`；句柄不存在时也返回 `{}` |
| `POST /notify` | 实例 | `{type}` → `{}`，`type` 为 `approval` 或 `pairing`。句柄不存在、或推送令牌已被 APNs / FCM 判定失效时返回 `not_found`（同时删除这条登记）；超出限额返回 `rate_limited`；APNs / FCM 暂时不可用返回 `internal` |

### 5.2 通知内容

由中继按 `type` 生成，实例不能指定文字：

| `type` | 标题 | 正文 | 有效期 |
| --- | --- | --- | --- |
| `approval` | Harmonia | 有一个待批准的请求，打开 App 查看 | 120 秒 |
| `pairing` | Harmonia | 有设备请求接入，打开 App 查看 | 300 秒 |

- APNs：`apns-push-type: alert`、`apns-priority: 10`、`apns-expiration` 为当前时间加有效期、`apns-collapse-id` 为 `type`、`apns-topic` 为 App 的 bundle ID；载荷只有 `{"aps":{"alert":{"title","body"},"sound":"default"}}`，不带自定义字段。按登记时的 `apnsEnvironment` 选择正式或测试环境。
- FCM（HTTP v1）：`notification` 为标题和正文；`android.priority` 为 `HIGH`，`android.ttl` 为有效期，`android.collapse_key` 和 `android.notification.tag` 为 `type`，`android.notification.channel_id` 为 `approvals`；不带 `data`。
- 判定令牌失效、删除登记的答复：APNs 的 `BadDeviceToken`、`Unregistered`、`DeviceTokenNotForTopic`；FCM 的 `UNREGISTERED`。

### 5.3 限流

- **合并**：同一个句柄、同一种 `type`，10 秒内最多发出一条。窗口内再来的 `POST /notify` 不发送，照常返回 `{}`：手机上同一类通知本来只显示一条。
- **每个句柄**：每天最多发出 1000 条（合并掉的不计），超出返回 `rate_limited`。只作兜底，正常使用碰不到。
- **全局**：每分钟合计最多发出的条数，默认 1000，由中继的部署变量 `NOTIFY_GLOBAL_PER_MINUTE` 调整；超出返回 `rate_limited`。所有实例共用这份额度。
- **登记**：`POST /registrations` 每个网络每分钟 20 次、每天 200 次；网络的定义和 HMAC 保存方式同 3.8。
- 以上都按句柄（也就是每台手机）或手机所在的网络计算，与实例无关：一个实例上有多少用户都互不影响。`POST /notify` 不按来源网络限流：实例运行在 Cloudflare 上，出口 IP 是共用的。
- 超出时返回 `rate_limited` 和 `retryAfter`，这次通知丢弃，不排队。

### 5.4 清理与本地开发

- 最近一次登记或确认（`POST /registrations`、`PUT /registration`）已超过 90 天的登记删除。
- 只用于本地开发的变量 `DEV_FAKE_SENDER=true`：不连接 APNs、FCM，把要发的通知写进日志，其余行为不变。部署时不设置。
