# Issue #83 全链路验收记录

## 范围与结论

本记录覆盖服务器访问重构的收口阶段：#79 基线审计、#80 账户/授权模型、#81 原生三栏工作区、#82 拓扑图，以及 #83 的旧入口清理、授权操作可达性和交付验收。

当前结论是：源码路径、迁移策略和自动化检查通过；原生窗口视觉操作、真实远端 SSH、两台 Mac 的 iCloud/CloudKit 联调仍未验证，因此不能把本记录描述为完整实机验收。

## 旧入口与资源审计

| 项目 | #83 处理 | 保留理由 |
| --- | --- | --- |
| `ServerEditorView.swift` | 重命名为 `ServerAccessFormView.swift`，继续作为新增服务器兼容表单 | 当前新增/导入表单仍被 `ContentView` 使用；这是文件名纠偏，不是删除运行能力 |
| `ServerDetailView.swift` | 删除旧服务器详情页及 `ContentView` 的直接回退入口 | 旧详情与节点工作区重复，且授权“查看与撤销”曾错误地回到同一节点详情；授权详情已收敛到节点工作区 |
| `ServerWorkspaceView.swift` / `ServerListView.swift` | 保留列表与发现/导入边界 | 服务器一级工作区仍需要列表选择、发现与导入；详情操作由 `NodeWorkspace*` 承担 |
| `SSHAuthorizationWorkflowViews.swift`、`PasswordEntryView.swift` | 保留 | 它们承载失败恢复、后置密码补录和批量授权，不属于已废弃的旧详情入口 |
| `SnapshotStore`、HostV6/V6 shadow、AskPass/relay、资源文件 | 保留 | 仍是迁移、回滚、运行时辅助或验证边界；不能因为调用点不在新 UI 就删除 |

## 原生路径对照

| 用户路径 | 当前实现/证据 | 状态 |
| --- | --- | --- |
| 添加或导入服务器 | `ServerAccessFormView`、`ServerDiscoveryView`，保存后投影到统一拓扑 | 源码与编译证据 |
| 账户与授权 | `SSHAccountEditorView`、`SSHAccessSetupView`、`SSHAuthorizationWorkflowViews` | 源码与核心测试证据 |
| 失败恢复 | `SSHFirstAccessProgressView`、密码补录、Host Key 确认、写入后复检状态 | 核心测试覆盖，原生窗口未操作验证 |
| 成功/终态 | `authorized`、`authorizationWrittenAwaitingVerification`、`needsAuthorization` 等状态与审计记录 | 核心测试覆盖 |
| 新增网络路径 | `NodeEndpointEditorView`；编辑/删除会使地址相关检测证据失效 | `UnifiedTopologyAppModelTests` 覆盖 |
| 图谱关系 | `TopologyGraphProjector` 以 SSH connection profile 投影有向边，保留候选/当前路径和主机信任墓碑 | `TopologyGraphProjectorTests` 覆盖 |
| 查看与撤销设备授权 | 节点工作区“设备授权”内嵌账户级详情、刷新、指纹展示和撤销确认；撤销会同步同一账户的连接配置状态 | 源码与编译证据；真实远端撤销未验证 |
| 删除连接配置 | 节点工作区确认后墓碑化 profile，不自动撤销账户级远端授权 | `UnifiedTopologyAppModelTests` 覆盖 |

## 已执行检查

以下结果以本分支实际执行输出为准，最终 PR 前会重新执行全套检查：

- `swift build`：通过。
- `swift test --filter TopologyGraphProjectorTests`：6 个测试通过。
- `swift test --filter UnifiedTopologyAppModelTests`：10 个测试通过。
- `./script/test.sh`：KeyPortTests 193 个、KeyPortCoreTests 312 个通过；`KeyPortCoreChecks`、SSH relay fixture、AskPass FIFO 一次性消费检查通过。
- `git diff --check`：通过（本次收口检查）。

测试使用临时目录和独立 `UserDefaults`，没有覆盖用户运行时快照、密码或私钥。

## 迁移与未验证边界

- legacy `AppSnapshot` 仍作为兼容投影和迁移输入；新图谱与节点工作区读取统一拓扑。旧记录的 profile/account/key/host-key/auth 标识由迁移层保留，失败时不把远端写入误报为成功。
- SSH 会话、主机身份核验和远端公钥操作仍由本机 OpenSSH/Keychain/Host Key adapter 承担；账户授权属于 SSH account，profile/endpoint 只是访问路径。
- `script/build_and_run.sh`、AskPass 和 preconnect relay 等运行资源保留；本记录不以静态文件存在替代运行时启动证据。
- 未验证：真实 SSH 服务器上的安装/复检/精确撤销、两台 Mac 的独立密钥与跨设备 CloudKit 同步、Production CloudKit schema、发布签名，以及 ProxyJump 的实际执行。
- 未完成原生窗口截图、深色模式、VoiceOver、Full Keyboard Access 和三种窗口尺寸的视觉复核；Figma 参考未作为已验证的实现证据。

## 交付门槛

在总 PR 合并到 `main` 前，必须重新执行构建、全量测试和 `git diff --check`，确认只包含 #79–#83 范围内的源码、测试和文档；总 PR 需关联并关闭 #78–#83。若远端 SSH、两台 Mac 或 Production CloudKit 仍不可用，应在总 PR 和最终交付说明中保留上述未验证边界。
