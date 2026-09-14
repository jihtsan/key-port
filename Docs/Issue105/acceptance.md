# Issue #105：统一正式入口与旧实现退出

## 结果与范围

新 `KeyPortInterface` 是 `KeyPort.app` 唯一界面。`WorkspaceStore.Document.topology` 是唯一工作区写入源，SSH 输入和列表/Graph 都是只读投影。原正式版和 AccessPilot 不再并列运行。

| 原实现 | 当前实现/退出方式 |
| --- | --- |
| 旧 ContentView、侧栏、服务器/Graph/设备/密钥/设置页面与菜单栏 | 已删除；新三栏页面配合设备、授权、活动与设置面板。 |
| 5,419 行 AppModel、GraphWorkspaceModel | 已删除；统一 WorkspaceStore 直接读写拓扑。 |
| SnapshotStore、TopologyStore、HostV6 可切换运行时与应用层 CloudV2 写入 | 已删除；旧格式只在 WorkspaceMigration 首次读取。 |
| AccessPilot 独立可写状态和 bundle ID 开关 | 已删除；现有 AccessPilot 文件只读迁入，正式产品固定为 KeyPort.app。 |
| 旧 SSHConfigService、路由 feature flags、Tailscale/发现/隧道应用服务、旧 Keychain 密码与 Agent 管理 | 已退出当前应用；新流程仅本次密码与显式本机私钥，统一严格 OpenSSH 参数。 |
| ProcessRunner 内部无超时 Process 分支 | 已删除；始终使用有界 ProcessExecutor。 |
| 原界面绑定测试 | 随被删实现退出；保留领域/安全/协议测试，并添加新工作区、迁移、配置接管和同步竞争测试。 |

保留的旧格式模型和迁移算法用于读取已有数据、加密归档及历史回归，不拥有应用写权。独立 Relay/TunnelBroker 回归产品未被删掉，但新正式 App 不打包或启动它们。当前访问入口使用显式直连；服务、Tailscale 和旧自动地址策略等拓扑事实保持存储，不恢复旧工作台。

## 迁入的正式能力

- 节点、账户、地址、公钥、主机信任及授权关系持久化；保留没有路径的 SSH 节点。
- iCloud 手动/自动同步非敏感拓扑；私钥路径、本机验证、可达性与当前设备状态在同步边界隔离。网络等待期间发生的本地修改参与最终合并。
- 工作区设备与公钥查看、设备改名；账户＋精确指纹授权核对和撤销。撤销通过主机扫描、严格主机校验、本机密钥认证以及本机身份验证。
- 加密元数据导入/导出；导入数据不会带来此 Mac 的私钥或验证成功。
- 新建、重试、新地址、别名、默认路径、路径删除、终端交接使用同一工作区。路径删除不等于远端撤销。

## 数据与配置迁移

首次建立 `workspace-v1.json` 前读取并备份存在的旧快照和 AccessPilot 数据。源文件保留且不回写；后续启动只读新工作区。损坏文件、未完成旧事务和冲突阻止迁移，不发布空白替代数据。主机身份刷新保持稳定记录 ID，避免云端重复信任项。

旧 `~/.ssh/keyport/config` 只有在 ownership receipt 的哈希匹配、所有别名均有迁入记录时才备份退出。新配置事务失败时恢复旧生成文件；外部修改和未导入别名不会被覆盖。用户 SSH Config 的无关内容保留。

## 验证

完整脚本覆盖 SwiftPM 各测试目标、KeyPortCoreChecks、实际本机进程、受保护 AskPass FIFO 与独立 Relay 的本机 OpenSSH fixture。发布模式构建、应用签名校验及 `--verify` 启动检查均执行；最终命令摘要见 `verification.txt`。

原生 UI 检查使用 `/tmp/keyport105-ui-workspace`，运行正式 KeyPort 入口：空白首页、设备面板、iCloud/归档设置和单表单字段均已读取与查看。用于列表/Graph 检查的数据为 `example.invalid`、未验证状态，不执行 SSH，不作为真实服务器验收。

## 尚未由本次验证证明的边界

- 原有实际工作区的迁移未用于测试；未读取密码、私钥内容，也未代用户确认主机指纹或执行真实远端授权/撤销。
- ad-hoc 构建明确不可用 CloudKit；真实双 Mac 同步、有效团队签名下 CloudKit 和 Production 发布仍需对应环境验收。
- 主机重置后的身份替换与重新授权仍属于 #100，不自动接受新指纹。
- 旧资料中的 VPN/RDP、跳板、隧道工作台和 Tailscale 发现不构成新入口的功能承诺。
