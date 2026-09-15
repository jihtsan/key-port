# KeyPort

KeyPort 是 macOS 原生 SSH 免密授权管理工具。新三栏界面是唯一正式入口：服务器列表与 Graph 共用工作区、选择和检测结果，本机 OpenSSH 负责认证和终端会话。

## 当前功能

- 单表单填写别名、描述、地址和账户，使用本次密码或指定本机私钥完成主机指纹确认、登录、公钥授权和免密复验。
- 同服务器的账户授权与连接地址分离；新增地址需核对身份，不重复安装已有公钥。
- 选择默认路径、修改别名、删除路径、复制命令并交接系统终端。删除路径不会撤销远端公钥。
- “我的设备”查看设备、公钥指纹和账户授权，修改设备名称，核对远端授权或按精确指纹撤销。撤销需本机身份验证。
- “设置”手动或自动同步 iCloud 非敏感元数据，以及导入/导出加密元数据归档。
- “活动记录”显示此 Mac 保存的最近访问验证；这些是带时间的检测结果，不是实时在线状态。

密码只用于当前操作的内存和受保护的 AskPass FIFO，不保存到快照、参数、日志或 Keychain。私钥留在本机，不进入 CloudKit 或元数据归档。云端授权记录不等同于当前 Mac 已通过 SSH 验证。

## 构建与验证

需要 macOS 14+、Swift 6 工具链与系统 OpenSSH。

```bash
./script/test.sh
swift build -c release
git diff --check
./script/build_and_run.sh --verify
```

输出为 `dist/KeyPort.app`。默认使用 ad-hoc 签名，不能访问 CloudKit；启用 iCloud 需有效团队证书与 provisioning profile：

```bash
KEYPORT_SIGNING_IDENTITY="证书 SHA-1 或名称" \
KEYPORT_PROVISIONING_PROFILE="/path/to/KeyPort.provisionprofile" \
  ./script/build_and_run.sh --verify
```

签名配置见 [iCloud 配置与签名](Docs/iCloud-配置与签名.md)。脚本还支持 `--logs`、`--telemetry` 和 `--debug`。

隔离 UI 检查使用同一入口和同一代码，只替换存储根目录：

```bash
KEYPORT_WORKSPACE_HOME=/tmp/keyport-ui-check ./script/build_and_run.sh --verify
```

## 唯一工作区与迁移

`Sources/KeyPort/Features/Workspace/WorkspaceStore.swift` 直接写统一拓扑，不再使用 AppModel、旧 Graph 状态或 AccessPilot 独立写库。

| 文件 | 用途 |
| --- | --- |
| `~/Library/Application Support/KeyPort/workspace-v1.json` | 唯一工作区：拓扑、当前设备、本机路径密钥选择与默认路径。 |
| `~/.ssh/keyport/identities/` | 本机生成的密钥。 |
| `~/.ssh/keyport/known_hosts` | 已确认主机身份的本地投影。 |
| `~/.ssh/keyport/path-*.conf` | 指定路径的显式 OpenSSH 配置。 |
| `~/.ssh/keyport-access/config` | 新工作区管理的短别名配置，通过受控 Include 接入用户 SSH Config。 |

首次读取会迁入旧 `topology-v1.json` / `state-v1.json` 与 AccessPilot 数据；源文件先备份并保留，之后不再回写或重复导入。未完成的旧事务、损坏文件、身份冲突会阻止迁移，不创建空白替代数据。旧生成 SSH 配置需通过所有权哈希与已导入别名检查后才备份退出；用户自行修改的配置不会被覆盖。

## 工程边界

- `KeyPortInterface`：新界面、表单和流程状态；`KeyPortDesignPreview` 是独立开发预览，不是正式运行入口。
- `KeyPort`：统一工作区、单次迁移、CloudKit、归档、受限 OpenSSH 和原生窗口。
- `KeyPortCore`：领域模型、安全策略、配置与数据读取/迁移工具及其回归测试。旧格式类型保留于数据边界，不再持有应用写权。
- 正式应用只打包当前使用的 AskPass helper。Relay/TunnelBroker 独立产品与测试作为历史协议/迁移回归工具保留，不再由主应用启动或打包。

当前正式访问流程使用显式直连；旧的服务、Tailscale 元数据及自动地址策略保留在拓扑中，不提供旧工作台入口。当前主机扫描要求 ED25519 host key；带口令私钥的交互解锁、真实双 Mac CloudKit、正式签名发布与公证不由本地测试证明。

本次退出清单与验证记录见 [Issue #105 验收](Docs/Issue105/acceptance.md)。其他 [历史设计文档](Docs/README.md) 提供背景，当前运行行为以本文件和源码为准。

### 添加 Tailscale 地址

在服务器详情点击「添加地址」，或打开「添加或导入服务器」，在地址字段下选择「检测并导入 Tailscale 地址」。KeyPort 读取本机 Tailscale 客户端状态，显示设备的 MagicDNS、IPv4、IPv6 与本次检测到的在线状态；支持按设备名或地址搜索。点击「使用此地址」自动填入连接表单，再填写目标机器的 SSH 账户并完成原有验证流程。

添加现有服务器地址会保留服务器、账户、别名和端口。检测本身不写入服务器配置；Tailscale 在线不等于 SSH 可达或已授权。未安装、未连接、读取失败时可修复客户端状态后重新检测。
