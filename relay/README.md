# Harmonia 推送中继

替各个 Harmonia 实例给手机发系统通知（设计见 [docs/rewrite-plan.md](../docs/rewrite-plan.md) 第 18 节，接口见 [docs/protocol.md](../docs/protocol.md) 第 5 节）。只由发布者部署，自部署实例不需要它，也不会带上它。

## 本地开发

```bash
mise run test-relay   # 单元测试
mise run dev-relay    # 本地运行在 8788 端口，不连接 APNs、FCM，要发的通知写进日志
```

服务端用 `DEV_PUSH_RELAY_URL=http://localhost:8788` 连接本地中继；App 用 `--dart-define=DEV_PUSH_RELAY_URL=...`。

## 发布者部署

只需要准备一次：

1. **APNs**：在 Apple Developer 后台为 `org.harmoniavault.harmonia` 打开 Push Notifications，创建一个 APNs 密钥（.p8），记下 Key ID 和 Team ID。
2. **FCM**：在 Firebase 控制台建一个项目，添加 Android 应用 `org.harmoniavault.harmonia`；在“服务账号”里生成一个私钥（JSON）。
3. **Cloudflare**：在 Workers 的 `harmonia-relay` 设置里添加 Secrets：

   | 名称 | 内容 |
   | --- | --- |
   | `APNS_KEY` | .p8 文件的全部内容 |
   | `APNS_KEY_ID` | APNs 密钥的 Key ID |
   | `APNS_TEAM_ID` | Team ID |
   | `APNS_TOPIC` | `org.harmoniavault.harmonia` |
   | `FCM_SERVICE_ACCOUNT` | 服务账号 JSON 的全部内容 |

   可选的变量 `NOTIFY_GLOBAL_PER_MINUTE`：全部手机每分钟合计的通知上限，默认 1000。
4. **GitHub**：仓库 Secrets 里添加：
   - 部署中继用：`CLOUDFLARE_API_TOKEN`（只授予 Workers 脚本和路由的编辑权限）、`CLOUDFLARE_ACCOUNT_ID`；
   - 构建 APK 用：`FIREBASE_APP_ID`、`FIREBASE_API_KEY`、`FIREBASE_PROJECT_ID`，在 Firebase 控制台的 Android 应用设置里可以找到。

之后每次打正式版本标签时，`deploy-relay.yml` 先跑测试再部署；也可以在 Actions 页面手动运行，或者在本机执行 `mise run deploy-relay`。第一次部署前 Secrets 还没有填写时，中继会把所有通知答复为暂时不可用，不影响实例的其他功能。

域名 `harmonia-push.zzz.sd` 写死在 App 和服务端代码里，部署时自动绑定为 Worker 的自定义域名。
