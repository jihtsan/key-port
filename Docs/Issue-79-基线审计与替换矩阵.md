# Issue #79：服务器管理与免密访问基线审计、替换矩阵

状态：审计与施工基线，尚未切换产品运行时。

本文件对应 [Issue #79](https://github.com/jihtsan/key-port/issues/79)，基于 `codex/issue-78-server-access-redesign` 的 `e4f95b9f161dc4e8bae4287b04d2b6d5a9010c08` 建立，当前工作分支为 `codex/issue-79-baseline-audit`。本阶段只记录事实、边界、迁移策略、验收矩阵和删除门槛；后续阶段必须通过各自的 Issue 分支和 PR 合并到 `codex/issue-78-server-access-redesign`，最后再由总 PR 进入默认分支。

## 1. 设计边界

本审计遵循父 Issue #78 和一期产品边界：

- KeyPort 管理节点、SSH 账户、地址、连接策略、设备公钥授权、主机密钥信任、非敏感状态和 SSH 配置投影。
- 本机 OpenSSH 负责主机密钥校验、身份认证、加密和 SSH 会话；KeyPort 不实现第二套 SSH 会话或凭据代理。
- 密码只用于首次验证和公钥安装，默认不保存；需要保存时进入 macOS Keychain，iCloud Keychain 是用户明确选择且签名/权限可用时的单独能力。
- iCloud 只同步非敏感元数据和授权事实，不同步密码、私钥、AskPass 内容或运行中的网络观察。
- 本期只支持直连。Jump host、ProxyJump 多跳、会话迁移和自动拓扑推断不是本次隐式扩展范围。
- `Graph` 是同一份节点/地址/账户/授权事实的投影，不能成为第二个可写事实源；列表、图和详情必须共享选择与状态。

本阶段没有 Figma MCP 或真实设计文件检查结果，因此不把 Figma 视觉一致性写成已验收项；视觉验收留给 #81 的真实 macOS 窗口检查。

## 2. 可复现基线

### 2.1 环境和 Git 状态

| 项目 | 基线事实 |
| --- | --- |
| 工作目录 | `/Users/joo00der/.codex/worktrees/3221/key-port` |
| 分支 | `codex/issue-79-baseline-audit` |
| 起点 | `e4f95b9f161dc4e8bae4287b04d2b6d5a9010c08`，`refactor: 清理一期已退役且无人调用的内部代码 (#77)` |
| Swift | Apple Swift 6.4，swift-driver 1.168.6 |
| macOS | 26.6.2 |
| OpenSSH | `OpenSSH_10.3p1, LibreSSL 3.3.6` |
| 初始工作树 | 干净；未纳入其他 worktree 的文件 |

### 2.2 命令结果

| 命令 | 结果 | 说明 |
| --- | --- | --- |
| `swift build` | 通过，退出码 0，26.48 秒 | 有一个已知弃用警告：`SystemNetworkHintProvider.swift:21` 使用 `CLLocationManager.authorizationStatus()`；不影响构建结果 |
| `./script/test.sh`（首轮） | 失败 | `ProcessExecutorTests.testExitStatusAndSeparatedOutputAreCaptured` 观测到 `timedOut(forcedKill: false)`，期望 `exited(3)`；未把一次偶发超时误记为稳定回归 |
| `swift test --filter ProcessExecutorTests.testExitStatusAndSeparatedOutputAreCaptured` | 通过 | 同一测试定向重跑，1 个测试、0 个失败 |
| `./script/test.sh`（完整重跑） | 通过，退出码 0 | Core 304 个测试通过；CoreChecks、AskPass FIFO、SSH Relay 和 OpenSSH 相关检查均完成 |
| `./script/test_c4.sh` | 受支持性条件跳过，退出码 0 | 本机为 OpenSSH 10.3p1，脚本明确报告 `C4 fixture skipped: unsupported OpenSSH version`；不能当作真实 C4 通过 |

基线结论：代码、核心测试、CoreChecks、AskPass 和 Relay 的离线/fixture 检查可通过；真实 macOS 窗口、有效团队签名下的 CloudKit、双 Mac 同步和真实凭据服务器尚未在本阶段验收。

## 3. 运行时与资源链路

### 3.1 SwiftPM 产品

`Package.swift` 当前声明以下可执行产品和一个核心库：

| 产品 | 责任 | 当前检查 |
| --- | --- | --- |
| `KeyPort` | SwiftUI/AppKit 主应用 | `KeyPortApp` 创建 `WindowGroup`、菜单栏入口和 Settings |
| `KeyPortAskPass` | 一次性密码 FIFO 的 OpenSSH AskPass 适配 | `./script/test.sh` 构建并消费受保护 FIFO |
| `KeyPortSSHRelay` | 连接前候选地址的有界字节转发 | `./script/test.sh` 和 `test_ssh_relay.sh` 覆盖版本、IPv4/IPv6、失败与取消 |
| `KeyPortTunnelBroker` | 本地服务/隧道生命周期 | `./script/test.sh` 构建；业务验收仍需按 #82 的边界检查 |
| `KeyPortCoreChecks` | 核心不变量 smoke check | `./script/test.sh` 执行 |
| `KeyPortCore` | 模型、迁移、规划、命令、投影和解析 | 304 个 Core 测试通过 |

### 3.2 运行时启动和打包

- `Sources/KeyPort/App/KeyPortApp.swift:22-41` 声明主窗口、菜单栏和 Settings；`AppDelegate` 在 `:101-114` 激活应用并在没有恢复窗口时请求新窗口，`AppWindowFallback` 在 `:171-194` 提供兜底窗口。
- `script/build_and_run.sh:47-79` 会构建主程序、AskPass、Relay、TunnelBroker，复制到本地 `.app` 的 `Contents/MacOS`、`Helpers` 和 `Resources`；`:89-127` 生成并校验 `Info.plist`；`:129-137` 的默认模式是 ad-hoc 签名并明确关闭 iCloud 能力。
- `script/build_and_run.sh:139-318` 的团队签名路径要求 provisioning profile，并校验 Team ID、App ID、CloudKit 容器、CloudKit 环境、Keychain group 和最终签名 entitlement。它是打包证据，不等于已完成真实 CloudKit/Production 验收。
- 当前资源只有 `Sources/KeyPort/Resources/key-hub@1x.png` 和 `key-hub@2x.png`。主应用通过 `Bundle.main` 或 `KeyPort_KeyPort.bundle` 查找资源；没有把“资源存在”扩展解释为已完成视觉验收。
- `Resources/KeyPort.entitlements:5-20` 声明 CloudKit、iCloud Keychain group 和 Development 环境。ad-hoc 本地运行不会拥有可用的团队签名能力。

### 3.3 密码、主机密钥和 OpenSSH 边界

- `OpenSSHService` 统一调用 `/usr/bin/ssh`，密码通过临时 `0700` 目录内的 FIFO 和 AskPass 传递，不进入参数；`Sources/KeyPort/Services/SSH/SSHService.swift:47-84,129-155,189-223`。
- FIFO 在一次读取后清空内存并由 `cleanup()` 删除临时目录；`SSHService.swift:250-320`。这保留为凭据边界，不迁移成字符串命令拼接。
- `HostKeyService` 使用 `ssh-keyscan` 或带受限临时 known_hosts 的 OpenSSH 探测，并把确认后的行写到 KeyPort 自有 `known_hosts`；`Sources/KeyPort/Services/HostKey/HostKeyService.swift:31-111`。
- `TrustedSSHSession` 只有在主机密钥确认和当前设备公钥探针通过后建立，远端命令是闭集 `SSHRemoteCommand`；`Sources/KeyPort/Services/SSH/TrustedSSHSession.swift:12-16,35-74`。
- `KeychainService` 以账户稳定 ID 为 Keychain account，保存用户名元数据和密码数据，默认本地 Keychain；只有显式同步且 entitlement 可用时才进入 synchronizable namespace；`Sources/KeyPort/Services/Keychain/KeychainService.swift:63-130,191-257`。
- `SSHConfigService` 只派生 KeyPort 自己的 `~/.ssh/keyport/config` 和 relay manifest，并把 include 写回用户 `~/.ssh/config`；已有托管配置、清单和 helper 的 hash/权限不匹配时 fail closed；`Sources/KeyPort/Services/SSHConfig/SSHConfigService.swift:137-260,396-459,581-606`。

## 4. 当前事实源与读写审计

### 4.1 领域事实的唯一归属目标

后续实现统一使用下表的术语。`Node`/`Host` 是同一类远端主体，产品代码最终保留一个公开命名；本阶段不在文档中把地址、账户或连接配置再称作“服务器节点”。

| 事实 | 目标唯一归属 | 当前实现 | 当前问题/迁移要求 |
| --- | --- | --- | --- |
| 远端主体 | `TopologySnapshot.nodes`（最终对应 V6 `Host`） | `TopologySnapshot` 已有 `Node`；V6 有 `Host`；legacy `ServerConnection` 也把 host/name 当主体 | 三套 ID/生命周期并存；#80 前不得删除旧数据，#83 前不得保留第二套可写主体事实 |
| 网络地址 | `TopologySnapshot.endpoints`（最终对应 V6 `AccessAddress`） | 新模型支持多地址；legacy 每个 `ServerConnection` 只有 `host + port`；V6 有 `AccessAddress` | legacy 迁移和 UI 仍会把地址当服务器记录；同主体新增地址必须不创建新授权 |
| SSH 账户 | `(Node, normalized username)` 的 `SSHAccount`（最终对应 V6 `SSHIdentity` 的账户语义） | `TopologySnapshot.sshAccounts` 已有稳定 ID；`AppModel` 新编辑器能读写它，但写入被 V6 runtime gate 阻断 | #80 必须让账户独立于地址；改名/合并要迁移 Keychain owner、授权和验证引用 |
| 连接配置/别名 | `SSHConnectionProfile`：账户 + 地址策略 + alias | `TopologySnapshot.sshConnectionProfiles`；legacy `ServerConnection.alias`；SSH config 从 legacy projection 派生 | alias 不是账户身份；固定/自动候选策略必须单独存储；不能因换地址复制授权 |
| 设备与本地私钥 | 设备/本地 key profile，私钥仅本机 | legacy `Device`/`SSHKeyRecord` 有私钥路径；V6 `SSHKeyRecord` 只同步公钥/指纹，local state 保存本机事实 | 云 payload 不得出现私钥路径、私钥内容或密码；跨 Mac 只共享公钥和授权事实 |
| 主机密钥信任 | 地址级 `SSHHostKeyTrust` / V6 `HostKeyPin` | legacy `confirmedHostKeys` 嵌在每条 `ServerConnection`；topology 有 endpoint 级 trust；V6 有 pin/known-hosts line | 地址级 mismatch 不能被另一个地址的成功覆盖；重确认是显式恢复动作 |
| 可达性 | 本机、地址、网络 epoch、时间戳的短期观察 | topology `ReachabilityObservation`；AppModel 有本地 status，但 `recordSSHConnectionEvidence` 当前写入 `networkEpoch: 0` | 与授权分离；unknown/过期不能渲染为失败或成功；#80 加入实际 epoch 和有效期 |
| SSH 访问验证 | 账户 + 设备 + profile/地址 + 时间戳的本地证据 | topology `AccessVerification`；legacy `passwordCheck/keyCheck/lastCheckedAt` 仍被 UI 读取 | 不把 metadata sync 当作 SSH auth；结果必须区分未检测、已过期、失败和通过 |
| 远端公钥授权 | 账户级 key fingerprint 关系 | topology `SSHAuthorization`；V6 `Authorization` 绑定 `sshIdentityID`；legacy `Authorization` 以 `serverID`（实际常为 profile）保存 | legacy `upsertAuthorization` 会向同账户的多个 profile fan-out；迁移必须收敛到账户级事实 |
| 连接前候选 | `SSHConnectionProfile.routePolicy` + 有序候选地址 | Relay manifest 从 topology profile 和 legacy server 生成 | 只允许 pre-connect unreachable fallback；身份、主机密钥、会话错误不得静默切换 |
| UI 图/列表 | 纯投影和选择状态 | `GraphWorkspaceModel` 可从 V6 envelope 或 topology 更新；服务器列表仍从 `snapshot` 读取 | #82 统一查询和选择源；Graph 不创建“主机/账户/地址”第二份图数据 |

### 4.2 当前三套模型及运行时方向

```text
V6 MetadataEnvelope (Cloud/authority, Host + Address + SSHIdentity + local evidence)
                 │  compatibilityProjection / shadow staging
                 ▼
TopologySnapshot (Node + Endpoint + SSHAccount + Profile + local observations)
                 │  legacyProjection / refreshed
                 ▼
AppSnapshot (ServerConnection + legacy Device/Key/Authorization + UI status)
                 │
                 ├─ AppModel.activeServers / selectedServer / auth / config write
                 └─ Server workspace / old editor / key and device compatibility views

GraphWorkspaceModel ← V6 envelope 或 TopologySnapshot（当前存在两条更新入口）
SSHConfig/SSHService/HostKey/Keychain ← AppModel 的 legacy projection 参数
```

事实结论：`AppModel` 明确把 `snapshot` 标为 compatibility projection（`Sources/KeyPort/Stores/AppModel.swift:396-400`），但 `activeServers`、选择、授权、配置写入和大部分检查仍从它读写（`:520-555` 以及 `:2288-2533`）。没有把“标记为兼容”变成“实际上只读”。

V6 runtime 当前在 `Sources/KeyPort/App/HostV6RuntimeAssembly.swift:22-28,66-175` 中按 authority manifest 返回 legacy snapshot 或兼容投影；`AppModel.requireLegacyMutation()`（`:4896-4900`）只做 authority gate。因此 V6 authoritative/rollback 下，新账户、地址、配置、授权和撤销等 AppModel 入口会被阻断，而不是转译为 V6 command。这是后续阶段必须修复的迁移断点。

## 5. 文件/模块替换矩阵

矩阵中的“保留”表示继续作为唯一实现或迁移适配器保留；“替换”表示新实现接管调用方后，旧实现只可短期只读恢复；“删除”必须等到对应退出条件满足后执行，不能只按文件名清理。

| 当前文件/模块 | 当前职责和调用方 | 决策 | 接管模块/阶段 | 删除或退出条件 |
| --- | --- | --- | --- | --- |
| `Sources/KeyPort/Stores/AppModel.swift` | 所有 UI 状态、legacy snapshot 写入、SSH/Keychain/Cloud 调度 | 拆分并降级为应用协调器；不再拥有领域数组 | `ServerAccessStore`/`EnrollmentCoordinator`/`AccessCoordinator`/`SyncCoordinator`；#80–#83 | AppModel 不直接改 `snapshot.servers/authorizations`；旧字段仅 compatibility/recovery 读取；全链路测试通过 |
| `Sources/KeyPortCore/Models/DomainModels.swift` | `ServerConnection`、legacy Device/Key/Authorization、AppSnapshot schema 5 | 保留解码、导入和恢复；禁止新 UI 依赖 | `TopologyModels`/V6 model；#80–#83 | 迁移样本可 round-trip；没有活跃入口写 AppSnapshot；删除前保留可恢复导入 |
| `Sources/KeyPortCore/Topology/TopologyModels.swift` | Node/Endpoint/Account/Profile/Trust/Auth/Observation，legacy↔topology migration/projection | 收敛为本地应用模型或明确 V6 adapter；修复 host/port 分组和 account-level auth fan-out | `AccessDomain` + V6 adapter；#80 | 新增/编辑/删除/同步均通过唯一 command；legacy projection 只读且有回滚记录 |
| `Sources/KeyPortCore/Hosts/HostV6Models.swift` | Cloud/authority 的 Host/Address/SSHIdentity/device/key/pin/auth/local state | 保留为共享元数据 authority；明确 SSHIdentity 与账户/profile 的映射 | V6 metadata repository；#80–#83 | V6 写命令覆盖所有产品写场景；authority gate 和 Cloud schema 有真实签名证据 |
| `Sources/KeyPort/Stores/TopologyStore.swift` | `topology-v1.json` 原子保存/加载 | 保留并补备份、版本、恢复选择 | `AccessStore` 的唯一本地快照；#80 | 保存前 checkpoint；损坏/中断可恢复；旧文件不会被静默覆盖 |
| `Sources/KeyPort/Stores/SnapshotStore.swift` | `state-v1.json` legacy 保存；V6 shadow staging 输入 | 保留为只读兼容/迁移输入；不再作为活跃写源 | `TopologyStore`/V6 authority；#80–#83 | V6/local authority 完成双读验证；迁移失败仍可恢复旧文件；无新写调用 |
| `Sources/KeyPort/Stores/GraphWorkspaceModel.swift` | 从 V6 envelope 或 topology 生成 graph projection，拥有选中/过滤 | 保留并改为单一 `AccessSnapshot` 输入 | `GraphProjection`；#82 | list/graph 查询同一 snapshot；不再有 topology/envelope 双入口造成可见状态分叉 |
| `Sources/KeyPort/Stores/HostV6MutationWorkflow.swift` | V6 command journal、幂等、外部 effect、撤销远端分段流程 | 保留并扩展 command 覆盖账户/地址/profile/授权流程 | V6 repository command boundary；#80–#83 | 不是仅删除命令；所有敏感副作用有可恢复 journal，remote revoke 的失败状态可见 |
| `Sources/KeyPort/App/HostV6RuntimeAssembly.swift` | feature flags、canary/authoritative/rollback、compatibility projection | 保留为一次性迁移/回滚入口，移除“authoritative 阻断旧写”的长期状态 | `AccessRuntimeAssembly`；#83 | 新路径在 authoritative 下可工作；rollback 明确只读；feature flag 无永久 V2/V6 分叉 |
| `Sources/KeyPort/Features/Servers/ServerEditorView.swift` | 旧服务器 + 首个账户表单、单独检查/保存 | 替换 | `SSHAccessSetupView` 的单一首访表单；#81 | 新表单覆盖新增和导入；旧 sheet/多步入口无调用；密码默认不持久化 |
| `Sources/KeyPort/Features/Servers/ServerWorkspaceView.swift` / `ServerListView.swift` / `ServerDetailView.swift` | 服务器账户中心列表/详情/工具栏 | 重构并最终收敛到节点工作区 | `NodeWorkspace*` + `GraphWorkspaceView`；#81–#82 | 3 pane 下名称/地址/账户/授权/策略可完整操作；不再存在重复服务器状态 |
| `Sources/KeyPort/Features/Servers/SSHAuthorizationWorkflowViews.swift` | 批量授权、旧授权动作和多步状态 | 保留能力，替换交互和状态输入 | `AccessCoordinator` + 账户详情；#81/#83 | 失败阶段、取消、重试、写后复检可从同一状态恢复；不再有独立旧流程入口 |
| `Sources/KeyPort/Features/Servers/PasswordEntryView.swift` | 后置密码补录/可同步保存/授权后动作 | 降级为恢复路径，不作为首访主路径 | 单表单临时密码；#81 | 首次添加不再强制二次 sheet；后置补录仍可在失败恢复中使用且默认不保存 |
| `Sources/KeyPort/Features/Graph/*` | Graph/list/detail 投影和节点编辑入口 | 保留并成为主工作区 | `AccessSnapshot`/`GraphProjection`；#81–#82 | 图和列表共享选择、过滤和 CRUD；图只显示真实关系、方向和验证事实 |
| `Sources/KeyPort/Features/Keys/KeyViews.swift` | 独立密钥一级入口和服务器密钥详情 | 删除一级导航，保留设备详情内的必要能力 | `My Device` / access detail；#82/#83 | 无独立 `.keys` 入口；密钥生成/导入/agent/revoke 仍可从明确上下文操作 |
| `Sources/KeyPort/Features/Devices/DeviceViews.swift` | 独立设备列表、批量授权入口 | 保留并调整为 My Device | `DeviceWorkspace`；#82 | 设备、密钥、此 Mac 授权状态与账户详情使用同一 snapshot |
| `Sources/KeyPort/Features/Logs/*` | 独立 Logs 与 Activity 重复入口 | 合并 | `GraphActivityView`；#81/#83 | 只有一个 Activity/Audit 入口，清理重复 view 和导航 case |
| `Sources/KeyPort/App/AppSidebarView.swift` / `ContentView.swift` | 旧 servers/keys/devices/logs 导航和多个 sheet | 重构为原生三栏入口和单一表单路由 | `AppShell`；#81 | sidebar 只暴露产品一级工作区；所有旧 sheet 调用点消失；真实窗口截图/窄宽度/键盘检查通过 |
| `Sources/KeyPort/Services/SSHConfig/SSHConfigService.swift` | legacy server/auth 输入生成 config/relay | 保留为派生适配器，改收 canonical access snapshot | `SSHConfigProjection`；#80/#83 | 只由 canonical state 生成；原有托管块 hash、备份、fail closed 和 relay 边界测试保留 |
| `Sources/KeyPort/Services/SSH/SSHService.swift` | 密码检查、公钥安装、复检、撤销、机器信息 | 保留底层 OpenSSH adapter；上层改为阶段化 coordinator | `EnrollmentCoordinator`/`AccessCoordinator`；#80–#83 | 直接 OpenSSH 调用仍集中；不向 UI 泄露秘密；错误阶段可映射到稳定状态 |
| `Sources/KeyPort/Services/HostKey/HostKeyService.swift` | endpoint 主机密钥扫描与 known_hosts | 保留并改为 endpoint 级输入 | `HostIdentityVerifier`；#80/#81 | mismatch/pending/confirmed 三态按地址显示；不因其他地址成功而跳过复核 |
| `Sources/KeyPort/Services/Keychain/KeychainService.swift` | 账户凭据存取 | 保留；owner 从 profile/server ID 迁移到账户 ID | `CredentialStore`；#80/#81 | 同一账户多地址只保留一个 owner；默认 no-save；迁移/删除有回滚和清理记录 |
| `Sources/KeyPort/Services/CloudSync/*` | legacy Topology CloudKit 与 V6 V2 CloudKit 并存 | 收敛为 canonical metadata sync；保留旧记录读取/迁移 | `SyncCoordinator`；#80/#83 | 一种主 payload；没有密码/私钥；Development/Production 和双 Mac 验收证据分开记录 |
| `Sources/KeyPort/Support/TerminalService.swift` / `ClipboardService.swift` | 外部终端和剪贴板副作用 | 保留窄适配器并补成功/失败反馈 | `AccessDetailActions`；#81/#83 | 复制结果可验证；终端只通过 OpenSSH alias/命令，不把密码放入命令或日志 |
| `Sources/KeyPortAskPass/main.swift` / `Sources/KeyPortSSHRelay/main.swift` | 辅助进程 | 保留；不扩展为业务状态源 | SSH adapters；#80/#83 | 版本、权限、FIFO 一次读取、取消、边界错误均有检查；仅 pre-connect fallback |

## 6. 迁移、备份与恢复策略

### 6.1 输入、目标和 checkpoint

当前持久化位置由 `Sources/KeyPort/Support/KeyPortPaths.swift:10-68` 定义：

- `state-v1.json`：legacy `AppSnapshot`；当前 schema 5。
- `topology-v1.json`：Topology `TopologySnapshot`；当前 schema 4。
- `state-v6.json`、`state-v1-compat.json`、`authority-manifest.json`：V6 authority 与兼容投影。
- `v6-checkpoints/`、`v6-commit-staging/`、各类 journal：V6 提交和恢复材料。
- `~/.ssh/keyport/config`、`config.derivation.json`、`known_hosts`、relay manifest：KeyPort 派生 SSH 资产。
- Keychain：账户密码和用户名元数据；不在 JSON/CloudKit 中复制。

`SnapshotStore` 和 `TopologyStore` 当前都做原子写和 `0600` 文件权限（`Sources/KeyPort/Stores/SnapshotStore.swift:17-47`、`Sources/KeyPort/Stores/TopologyStore.swift:22-33`），但普通 Topology 保存没有独立的迁移 checkpoint/版本 journal。因此 #80 的首个写入必须先：

1. 读取并校验所有现有输入；任何 decode、引用或 alias 冲突都停止，不覆盖原文件。
2. 将旧 JSON、当前 topology、KeyPort managed SSH config、known_hosts、relay manifest 和 derivation state 复制到带 schema/时间戳/哈希的 KeyPort 私有 checkpoint；不复制私钥和密码。
3. 生成 canonical topology/V6 payload；完成引用验证、别名冲突检查、账户 ID 重映射和地址级主机密钥映射后再原子提交。
4. 由旧文件和新文件分别投影读取，逐项比较主体数量、地址、账户、alias、host key、授权、设备和状态；比较失败时回滚 presentation，不删除输入。
5. 只有提交和派生 config/known_hosts 成功后，才记录 migration completion；外部副作用失败必须显示 pending/recovery，而不是把元数据伪装成完全成功。

### 6.2 兼容迁移的具体规则

- legacy `ServerConnection` 的稳定 ID 先作为 profile/来源 ID 记录，不能直接把每条记录当作一个新节点。
- 当前 `TopologySnapshotMigration.fromLegacy` 在 `Sources/KeyPortCore/Topology/TopologyModels.swift:855-1070` 按 normalized host 组织节点；审计发现该逻辑需同时纳入 port/协议，避免两个不同端口被错误合并。#80 必须先补测试再改变生产迁移。
- 当前 `legacyProjection` 在 `TopologyModels.swift:1638-1774` 为连接 profile 生成 legacy server，并可能把账户级授权展开到多个 profile；这只能作为兼容读投影，不能反向成为授权事实。#80 必须验证“同账户新增地址不重复安装/复制授权”。
- 账户 canonical ID 为 `(nodeID, normalized username)`；修改用户名不能静默丢失 Keychain、授权或验证，必须通过显式 migration map 和旧 owner 清理 journal。
- 地址删除只有在 profile 已迁移、固定地址已清理或明确替换后才允许；若是主体最后一个可用地址，按域模型拒绝删除并保留恢复信息。
- 任何 host key mismatch 都停止该 endpoint 的认证/授权动作；不能用另一个地址的成功结果覆盖当前地址的观察。
- `state-v1.json`、`topology-v1.json` 和 V6 compatibility projection 不在 #80 立即删除；它们必须至少经历一次启动恢复、导出/导入和损坏文件恢复测试，#83 才能确定删除或永久只读保留。

### 6.3 外部文件和秘密边界

- 用户 `~/.ssh/config` 只追加/维护 KeyPort 自己的 include；非 KeyPort 内容不能被重写。
- KeyPort 派生 config/manifest/known_hosts 使用 owner-only 权限、hash/备份和 fail-closed 校验；现有实现的安全行为是验收基线。
- 密码只在内存和 Keychain；私钥只在用户本机路径或 agent；CloudKit payload、metadata archive、audit、测试 fixture 和 Git diff 都不得出现它们。
- `SSHConfigService` 的 relay manifest 仅表达有序 pre-connect 候选；Relay 不负责 SSH 认证、密码、配置同步或会话迁移。

## 7. 分阶段施工与验收门槛

| 阶段 | Issue/分支 | 必须交付 | 进入下一阶段的硬门槛 |
| --- | --- | --- | --- |
| 基线 | #79 / `codex/issue-79-baseline-audit` | 本文件、真实 build/test 结果、读写审计、替换矩阵、迁移策略 | 本 PR 合并到 integration；矩阵已由 PR review 接受；没有代码行为变更 |
| 账户/地址/授权模型 | #80 / `codex/issue-80-account-access` | 账户与地址分离；同账户多地址不重复授权；reachability/auth/recent SSH 分离；canonical V6/topology 写入口 | 相关 Core/App tests 通过；迁移 backup/recovery 通过；authoritative 下真实写命令可用；jump host 未引入 |
| 原生三栏/单一首访 | #81 / `codex/issue-81-native-access-flow` | 原生三栏、单表单、阶段化验证、默认 no-save、失败可恢复、真实 clipboard/terminal | 旧多步入口和重复状态无调用；真实 `.app` 窗口检查；敏感信息边界测试；macOS 14 API/字体 fallback 检查 |
| Graph/list/管理 | #82 / `codex/issue-82-graph-list-management` | Graph/list 共用 snapshot；地址 CRUD、策略/alias 冲突、授权查看/撤销/删除、发现/导入去重 | 真实节点/边事实和选择同步；撤销远端失败可恢复；权限/同步边界通过；没有 multi-hop |
| 清理/总验收 | #83 / `codex/issue-83-cleanup-acceptance` | 删除旧入口/重复状态/退役资源；全量脚本、CoreChecks、构建、业务链路、总 PR | 所有 critical migration/auth/identity failure 清零；默认分支包含总 PR；Issues/PR 闭环 |

### 7.1 功能验收矩阵

| 场景 | 成功事实 | 必须保持的失败事实 |
| --- | --- | --- |
| 新增主体和首个账户 | 一个 Node/Host、一个账户、至少一个地址/profile；可进入验证阶段 | 缺少名称/地址/账户、端口或 alias 冲突时不写入半成品 |
| 首次连续验证 | 可达性 → 主机身份 → 密码/已有设备密钥 → 写入公钥 → 公钥复检；每阶段可见 | unreachable、host key pending/mismatch、密码拒绝、密钥不可用、写后复检失败、取消必须可重试且不丢名称/地址/账户 |
| 同账户新增地址 | 只新增 address/profile，复用账户和现有授权事实 | 不重复保存密码、不重复安装公钥、不因地址名相同错误合并不同主体 |
| 同主体多账户 | 账户分别显示、分别保存/验证、分别生成 alias | 一个账户的 auth/失败状态不能污染另一个账户 |
| 固定/自动策略 | fixed 只用指定地址；automatic 只按有序候选在连接前处理 unreachable | host key/auth/session 错误不静默切换；未知/过期状态不假装健康 |
| Graph 与列表 | 同一对象选择、同一状态、同一详情；边显示事实来源/方向/验证时间 | 不创建推断节点、反向边或独立 auth/address 状态 |
| 撤销/删除 | 指定授权/账户/地址的作用域清晰；外部副作用完成或 pending 可恢复 | 远端撤销失败不能伪造本地成功；删除最后地址或有未解决身份冲突时拒绝 |
| 新 Mac | 云同步非敏感模型；本机密钥/Keychain 状态独立，用户可选择已有 key 或重新授权 | metadata sync 不能被显示为本机 SSH auth 成功；不下载密码/私钥 |
| SSH 输出 | 可复制 alias、打开外部终端，最终由本机 OpenSSH 建立会话 | 密码不进入参数、日志、剪贴板或 audit；relay 不承担 session/auth |

## 8. 当前未验证项与后续工作单

以下项目不是本阶段失败，但在 #83 前不能标成完成：

- 未在真实 macOS 窗口中验证三栏布局、长名称、窄窗口、键盘导航和表单可达性。
- 未使用有效团队签名验证 CloudKit Development/Production、iCloud Keychain 和跨两台 Mac；本地 ad-hoc 路径只能证明禁用/错误提示边界。
- 未对真实凭据服务器执行新增、host key 变更、密码拒绝、公钥写入后复检、撤销和外部终端完整链路。
- C4 fixture 因本机 OpenSSH 版本不受支持而跳过；需要受支持版本环境才能补充该证据。
- 需要补齐 `TopologySnapshotMigration` 的 host+port/protocol 合并测试、账户级授权迁移测试、真实 network epoch/过期测试，以及 authoritative V6 command 到 UI coordinator 的集成测试。

## 9. #79 结论

基线允许开始 #80，但只允许在本矩阵约束下推进：先建立 canonical account/address/access 写入边界，再逐步让 UI 和 SSH 派生适配器改用该边界；任何“继续保留旧入口同时增加新入口”的实现都不算完成。旧数据和恢复路径暂时保留，旧行为在新路径接管并通过验收后删除或明确降级为只读恢复。
