# KeyPort iCloud 配置与签名

KeyPort 当前是 macOS 14+ 应用，不是 iOS target。iOS 的 provisioning profile 不能直接替代 macOS App ID；需要在同一个 Apple Developer 团队下为 `com.jihtsan.KeyPort` 配置 macOS 能使用的签名和能力。

## 本机当前状态

- Xcode 已登录 Apple 账号，并能看到团队 `Tianwei Technology (Changzhou) Co., Ltd.`，角色为 Admin。
- 本机已有旧个人 Team 的 `Apple Development` 证书；当前团队证书为 `Apple Development: Ji Haotian (S55VU52B46)`，Team ID 为 `LPUCQWYT2V`。
- 本机当前已生成并验证 `KeyPort macOS` macOS development provisioning profile，最新下载文件为 `~/Downloads/KeyPort_macOS-2.provisionprofile`，profile UUID 为 `815c4104-20a9-402e-b6db-7906e9892955`。
- 最新 profile 已包含当前 Mac 的 Xcode 设备 UUID `00006032-0012705E119A401C`，并授权 `iCloud.com.jihtsan.KeyPort`。

当前账号、证书、设备注册和 profile 已满足本机 CloudKit/iCloud entitlement 的开发启动条件。涉及密码、双重验证码、协议接受或付款时仍由账号持有人亲自完成。

## 开发者后台

在账号状态恢复正常后，进入 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/)，按以下顺序配置：

1. 在 Identifiers > App IDs > Bundle IDs 中创建或确认显式 App ID：`com.jihtsan.KeyPort`。
2. 为这个 App ID 开启 iCloud，并关联容器 `iCloud.com.jihtsan.KeyPort`。
3. Keychain Sharing 由应用 entitlement 配置。应用使用的访问组需要使用 profile 声明的 App ID 前缀；构建脚本会优先从 profile 读取它，不把旧账号的 App ID 前缀和 Team ID 混用。
4. 在 Devices > Add new device 中选择 `macOS`，注册 Xcode 使用的设备 UUID。这个 UUID 不一定等于 `system_profiler SPHardwareDataType` 显示的 Hardware UUID；可以用下面命令读取 Xcode 的值：

   ```bash
   xcrun xcdevice list | jq -r '.[] | select(.platform == "com.apple.platform.macosx" and .simulator == false and .available == true) | .identifier'
   ```

   当前这台 Mac 的值是 `00006032-0012705E119A401C`。
5. 保存 App ID 后，在 Profiles > Development 中创建或编辑 `macOS App Development` profile，选择团队、`com.jihtsan.KeyPort` App ID、`Apple Development` 证书和当前 Mac 设备，然后下载 `.provisionprofile` 文件。
6. 也可以先回到 Xcode > Settings > Apple Accounts > Tianwei Technology (Changzhou) Co., Ltd.，点击 `Download Manual Profiles`。
7. 在 CloudKit Dashboard 的 Development 环境中确认私有数据库允许使用 `KPTopologyMetadata` record type。统一拓扑同步使用单条记录 `keyport-topology-v1`；首次运行可以创建这个 record type。字段为：

   - `payload`: Bytes
   - `schemaVersion`: Int64
   - `updatedAt`: Date/Time

   旧的 `KPMetadata/keyport-metadata-v1` 属于迁移前的兼容记录，新版本不会继续读写它，避免旧的 `AppSnapshot` 云端表示和统一 `TopologySnapshot` 并行合并。

8. 发布前在 CloudKit Dashboard 将 Development schema 部署到 Production，并将构建脚本的 `KEYPORT_CLOUDKIT_ENVIRONMENT` 改为 `Production`。

## 团队签名构建

默认构建仍使用 ad-hoc 签名，因此不会启用 iCloud：

```bash
./script/build_and_run.sh --verify
```

使用 Apple Development 证书进行本机 CloudKit 开发时，还必须下载针对这个 macOS App ID 的 development provisioning profile：

```bash
KEYPORT_SIGNING_IDENTITY="证书 SHA-1 或名称" \
KEYPORT_PROVISIONING_PROFILE="/path/to/KeyPort.provisionprofile" \
  ./script/build_and_run.sh --verify
```

当前团队签名证书指纹和 Team ID 如下；也可以用证书名称替换指纹。profile 必须使用这张团队证书，不能使用旧个人 Team 的证书：

```bash
KEYPORT_SIGNING_IDENTITY="4DB4483AF669D05D8101B016FD4B458A9FE0F452"
KEYPORT_TEAM_ID="LPUCQWYT2V"
```

当前可用 profile 下载到 `~/Downloads/KeyPort_macOS-2.provisionprofile` 后：

```bash
KEYPORT_SIGNING_IDENTITY="4DB4483AF669D05D8101B016FD4B458A9FE0F452" \
KEYPORT_TEAM_ID="LPUCQWYT2V" \
KEYPORT_PROVISIONING_PROFILE="$HOME/Downloads/KeyPort_macOS-2.provisionprofile" \
  ./script/build_and_run.sh --verify
```

脚本会校验 profile 的 Bundle ID 与 Team ID，再从 profile 或证书读取实际 Team ID。如果使用证书 SHA-1 指纹，则也可以显式提供 Team ID：

```bash
KEYPORT_SIGNING_IDENTITY="证书 SHA-1" \
KEYPORT_TEAM_ID="你的 Team ID" \
KEYPORT_PROVISIONING_PROFILE="/path/to/KeyPort.provisionprofile" \
  ./script/build_and_run.sh --verify
```

只有证书、没有 development profile 时，脚本会拒绝生成可运行的 iCloud 包；这是 macOS 对开发签名 entitlement 的正常要求。

检查构建产物：

```bash
codesign -dvvv --entitlements :- dist/KeyPort.app
spctl -a -vv dist/KeyPort.app
```

输出中应看到签名 Authority、非 `adhoc` 的 Signature、实际 TeamIdentifier，以及 `CloudKit` 和 `iCloud.com.jihtsan.KeyPort` entitlement。ad-hoc 构建显示 `TeamIdentifier=not set` 是预期行为。

## 双设备验证

1. 两台 Mac 登录同一 Apple ID，并确认 iCloud Drive/Keychain 可用。
2. 两台 Mac 都使用同一个团队签名的 `com.jihtsan.KeyPort` 构建；不要混用 ad-hoc 包。
3. 在设置中打开“通过 iCloud 同步非敏感元数据”，添加或修改服务器后等待自动同步，也可以点击“立即同步”。
4. 在第二台 Mac 确认服务器、Host Key、公钥、设备和授权元数据出现。
5. 服务器密码只在保存时选择“允许通过 iCloud Keychain 同步”；密码不会进入 CloudKit payload。
6. 在一台 Mac 撤销某个设备授权，再在另一台 Mac 同步，确认该授权不会因旧快照重新出现。

私钥、本机私钥路径、SSH Agent 状态、密码、检测结果和审计日志都不参与 CloudKit 同步。新 Mac 需要生成或导入自己的本机私钥，然后再执行服务器授权。

## 常见失败

- “没有有效的 CloudKit 签名”：当前运行的是 ad-hoc 包，或签名没有包含 iCloud entitlement。
- “CloudKit 拒绝访问”：App ID、容器、Bundle ID 或 CloudKit 环境不匹配。
- “预置描述文件不允许此设备”：先用 `xcrun xcdevice list` 读取 Xcode 的 macOS device ID，确认它出现在 profile 的 `ProvisionedDevices` 中；不要只对比 `system_profiler` 的 Hardware UUID。然后检查 profile 的 `com.apple.developer.icloud-container-identifiers` 是否包含 `iCloud.com.jihtsan.KeyPort`。容器列表为空时，先把容器关联到 App ID，再重新生成 profile。
- iCloud Keychain 开关不可用：当前包不是团队签名，或 Keychain Sharing capability/profile 尚未配置。
- 两台设备数据不一致：确认使用相同 Bundle ID、相同 Apple ID，并在 CloudKit Dashboard 检查 Development/Production 环境是否一致。
