# SSH KeyPort macOS 技术框架与组件选型

> **文档定位（2026-08-28）：** 本文保留 macOS 技术与安全选型背景；其中以服务器列表为中心的信息架构已被 Graph 目标架构取代。参见 [Graph 拓扑与跨设备授权架构](./Graph拓扑与跨设备授权架构.md)。

- 文档版本：V1.0
- 调研日期：2026-08-04
- 适用范围：SSH KeyPort 一期
- 目标：给出可落地的原生技术栈、第三方候选和动画使用边界

## 1. 选型结论

一期建议采用“原生框架优先、SSH 能力单独验证、动画按需引入”的策略。

推荐基线：

- Swift 6 与 Swift Concurrency。
- SwiftUI 主界面，少量 AppKit 互操作。
- `WindowGroup + NavigationSplitView + Settings` 的桌面应用结构。
- Observation 管理界面状态，Actor 隔离 SSH、Keychain、CloudKit 和文件操作。
- SwiftData 保存本地非秘密数据，CloudKit 使用显式同步适配层。
- Security.framework 管理 Keychain，LocalAuthentication 提供 Touch ID 或系统密码验证。
- CryptoKit 处理应用导出文件的认证加密和完整性校验。
- 高层 Swift SSH 客户端只负责 Host Key 校验、认证、授权文件维护和按需状态检测；系统 OpenSSH 只负责最终别名兼容性验证。
- 原生 SwiftUI 动画优先；第三方动画一期最多选择一个。

建议最低支持 macOS 14，使 Observation、SwiftData、`phaseAnimator` 和 `keyframeAnimator` 可作为稳定基线。macOS 26 的 Liquid Glass 使用可用性判断渐进增强，不能成为核心操作的唯一表达方式。

## 2. 推荐应用结构

### 2.1 Scene 结构

```text
WindowGroup("SSH KeyPort", id: "main")
  NavigationSplitView
    Sidebar
    Detail
    Inspector（按需）

Settings
  General
  Sync
  Security
  SSH
  Logs
```

主窗口使用 `WindowGroup`，以确保应用启动时正确出现并支持窗口恢复。设置使用独立 `Settings` Scene，不放进主窗口侧边栏。一期不需要 `MenuBarExtra` 或独立监控窗口。

### 2.2 主界面组件

| 区域 | 原生组件 | 用途 |
| --- | --- | --- |
| 侧边栏 | `NavigationSplitView`、`List(.sidebar)` | 服务器、密钥、设备、日志 |
| 服务器列表 | `Table` 或轻量 `List` | 排序、选择、状态扫描 |
| 详情区 | `ScrollView`、`LabeledContent`、`Grid` | 连接、Host Key、授权详情 |
| 辅助信息 | `.inspector` | 日志、指纹、诊断详情 |
| 搜索 | `.searchable` | 跨服务器、地址、账号和分组搜索 |
| 工具栏 | `.toolbar`、`ToolbarItemGroup` | 添加、检测、授权、更多操作 |
| 状态 | `ProgressView`、`Gauge`、`ContentUnavailableView` | 授权状态、检测进度、空状态和失败状态 |
| 设置 | `Form`、`Toggle`、`Picker`、`SettingsLink` | 同步、安全和路径配置 |
| 上下文操作 | `contextMenu`、`Commands` | 复制别名、检测、编辑、撤销 |

侧边栏保持原生 source-list 风格：一枚图标、一行标题和最多一行次要信息。Host Key、指纹和授权元数据放在详情或 Inspector 中，不把侧边栏做成卡片墙。

### 2.3 建议目录

```text
KeyPort/
  App/
    KeyPortApp.swift
    AppDelegate.swift
  Features/
    Servers/
    Keys/
    Devices/
    Enrollment/
    Logs/
    Settings/
  Models/
    ServerConnection.swift
    Device.swift
    SSHKey.swift
    Authorization.swift
  Stores/
    ServerStore.swift
    KeyStore.swift
    DeviceStore.swift
  Services/
    SSH/
    Keychain/
    CloudSync/
    SSHConfig/
    HostKey/
    AuditLog/
  Support/
    Errors/
    Formatting/
    FileSystem/
```

SSH、Keychain、CloudKit 和文件写入不能直接写在 SwiftUI View 或 ViewModel 中。它们应提供结构化请求、进度事件和可分类错误。

## 3. Apple 原生框架

### 3.1 核心推荐

| 框架 | 一期用途 | 结论 |
| --- | --- | --- |
| [SwiftUI](https://developer.apple.com/documentation/swiftui) | Window、侧边栏、表格、工具栏、设置、动画 | 主 UI 框架 |
| [AppKit](https://developer.apple.com/documentation/appkit) | 窗口细节、系统菜单和 SwiftUI 缺口 | 少量互操作 |
| [Observation](https://developer.apple.com/documentation/observation) | `@Observable` 状态模型 | 推荐，避免无必要的 Combine 层 |
| [Swift Concurrency](https://developer.apple.com/documentation/swift/concurrency) | SSH 任务、批量检测、取消、超时 | 核心并发模型 |
| [Security](https://developer.apple.com/documentation/security) | Keychain、密钥访问控制 | 必选，不建议用通用包装库替代安全策略 |
| [LocalAuthentication](https://developer.apple.com/documentation/localauthentication) | Touch ID、登录密码回退 | 必选 |
| [CloudKit](https://developer.apple.com/documentation/cloudkit) | 服务器、公钥、设备和授权元数据同步 | 必选 |
| [SwiftData](https://developer.apple.com/documentation/swiftdata) | 本地非秘密数据与查询 | 推荐，需验证迁移和 CloudKit 边界 |
| [CryptoKit](https://developer.apple.com/documentation/cryptokit) | `.keyport` 文件加密、摘要和完整性 | 必选；不替代 SSH 协议实现 |
| [Network](https://developer.apple.com/documentation/network) | DNS/TCP 端口预检与超时 | 推荐 |
| [OSLog](https://developer.apple.com/documentation/os/logging) | 隐私标记、结构化日志和诊断 | 必选 |
| [UniformTypeIdentifiers](https://developer.apple.com/documentation/uniformtypeidentifiers) | 注册 `.keyport` 文件类型 | 推荐 |
| [ServiceManagement](https://developer.apple.com/documentation/servicemanagement) | 登录启动或后台辅助程序 | 一期不需要，未来按需评估 |

### 3.2 SwiftData、Core Data 与 CloudKit

有三种可选方案：

| 方案 | 优点 | 风险 | 建议 |
| --- | --- | --- | --- |
| SwiftData 自动 CloudKit | 代码少、SwiftUI 集成自然 | 字段冲突、删除标记和同步诊断控制较弱 | 不建议直接承担全部同步规则 |
| Core Data + `NSPersistentCloudKitContainer` | 成熟、离线与历史跟踪能力强 | 模型和冲突处理复杂，开发认知成本较高 | 团队熟悉 Core Data 时可选 |
| SwiftData 本地 + 显式 CloudKit 服务 | 本地开发简洁，可精确控制 CKRecord、删除和冲突 | 需要维护映射和同步状态机 | 一期推荐，但先做同步原型 |

无论选择哪一种，Keychain 秘密都不能进入持久化模型。模型只保存稳定的逻辑定位信息，例如固定 service 和服务器记录 ID；不能把仅在当前设备有效的 opaque persistent reference 当作跨设备标识。

### 3.3 Keychain 分层

| Secret | Keychain 策略 | 是否同步 |
| --- | --- | --- |
| 服务器密码 | Synchronizable Keychain item | 用户可选 |
| 本机私钥口令 | 设备本地 Keychain item | 禁止 |
| CloudKit 账户状态 | 系统管理 | 不自行保存凭据 |
| 导出文件恢复密码 | 只在操作期间驻留内存 | 默认不保存 |

iCloud Keychain 项目与 Touch ID 不应混成一个模糊开关。推荐流程是：应用先使用 LocalAuthentication 完成本机身份验证，再查询可同步的服务器密码项目。具体 `SecAccessControl` 组合必须用两台真实 Mac 做原型验证。

服务器密码项目建议使用固定 service（例如 `com.jihtsan.KeyPort.server-password`）和稳定的服务器记录 ID 作为 account，使不同 Mac 能定位同一个同步项目，而无需同步 Keychain 的设备本地引用。

## 4. SSH 授权通信实现候选

KeyPort 不实现终端界面、交互式 Shell、端口转发产品功能或用户命令执行。SSH 能力只是免密授权管理的内部通信机制，范围限定为：

- 获取并校验 Host Key。
- 使用密码或公钥完成认证。
- 读取、安全更新和验证当前账号的 `authorized_keys`。
- 验证当前设备密钥是否仍然有效。
- 验证生成的 SSH 别名可以被系统 OpenSSH 正确解析和使用。

### 4.1 推荐路线

一期推荐混合实现：

1. 高层 Swift SSH 客户端负责 Host Key 验证、密码认证、必要的受控远端文件操作和授权验证。
2. 系统 `ssh` 和 `ssh-keygen` 只用于无秘密参数的兼容性检查、指纹辅助验证和最终别名登录。
3. 应用不提供 Terminal 启动按钮或内嵌终端，用户在外部工具中自行使用同步后的别名。

这样可以避免把服务器密码传给命令参数、环境变量或普通 stdin，同时保留系统 OpenSSH 的真实兼容性验证。

### 4.2 候选比较

| 候选 | 能力 | 优点 | 风险 | 结论 |
| --- | --- | --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 密码/公钥认证、Host Key validator、受控命令、SFTP | 高层 async API，SwiftPM，MIT，macOS 14+ | 能力超出产品需求；依赖 NIOSSH fork；算法、OpenSSH 格式和服务器兼容性需验证 | 首选原型候选，只封装授权所需最小能力 |
| [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) | SSHv2、密码/公钥认证、Session、转发 | Apple 维护、Apache-2.0、现代 Swift | 明确定位为协议构件而非完整客户端；需要自行实现大量客户端行为；只支持现代密码学集合 | 作为底层或备用，不建议一期直接裸用 |
| 系统 OpenSSH + `Process` | 与外部实际使用环境一致 | 兼容性最高、无需打包协议栈 | 密码自动化困难；askpass 生命周期和秘密边界复杂；错误解析依赖文本 | 只用于无秘密的最终验证，不负责密码注入 |
| libssh2 + 自建 Swift 封装 | 密码、公钥、SFTP、成熟 C 协议栈 | 算法兼容面广、控制力强 | C 依赖、签名打包、内存安全和 Swift 封装成本 | Citadel 验证失败后的备选 |

截至 2026-08-04，SwiftNIO SSH 最新发布为 `0.15.0`；Citadel 最新发布为 `0.12.1`。版本号只用于记录调研时状态，实施时应重新锁定并审计依赖树。

### 4.3 SSH 技术原型验收

在开发业务 UI 前，必须用真实 Linux/OpenSSH 环境验证：

- Ed25519 Host Key、用户公钥和密码认证。
- 常见 RSA 现有密钥的扫描与登录兼容性。
- 正确拒绝未知或变化的 Host Key。
- 密码不进入进程列表、日志和崩溃信息。
- 读取带 `from=`、`command=` 等选项的 `authorized_keys`。
- 使用临时文件、权限设置、备份和原子替换更新远端文件。
- 正确处理远端 shell 差异、无 SFTP、只允许 SFTP 和禁用密码认证等授权场景。
- 取消、超时、断网和服务器主动断开不会造成任务或文件损坏。
- 最终 `ssh <别名>` 使用 KeyPort Config 与本机私钥成功登录。
- 状态检测在认证成功后立即断开，不打开交互式 Shell，不执行用户命令。

任何库如果要求关闭 Host Key 验证、不能安全处理服务器密码或无法保留未知授权行，都不满足一期要求。

## 5. 辅助授权状态检测

状态检测直接属于服务器管理功能，不建立独立监控模块：

- 服务器列表工具栏提供检测按钮。
- 检测逻辑复用 SSH Service 的 Host Key 和公钥认证能力。
- 结果写回服务器状态、最后检测时间和结构化错误。
- 批量检测使用受限 TaskGroup，每台服务器独立超时和取消。
- 公钥认证成功后立即关闭连接，不申请 PTY 或 Shell Channel。
- 一期不实现独立监控页面、后台定时任务、菜单栏摘要或通知。

## 6. 原生动画与现代视觉能力

KeyPort 属于安全和运维工具。动画应表达状态、因果和层级，不应用于持续装饰。

### 6.1 原生优先清单

| API | 适合场景 | 建议 |
| --- | --- | --- |
| `symbolEffect` | 连接检测、同步、成功、警告状态图标 | 推荐，语义明确 |
| `contentTransition` | 数字、状态文字和计数变化 | 推荐 |
| `phaseAnimator` | “连接 → 验证 → 授权”阶段切换 | 推荐，macOS 14+ |
| `keyframeAnimator` | 精确的成功回弹或错误抖动 | 少量使用，macOS 14+ |
| `matchedGeometryEffect` | 列表选中项到详情标题的连续过渡 | 谨慎使用，避免破坏桌面选择稳定性 |
| `Canvas` + `TimelineView` | 自定义连接脉冲或轻量网络轨迹 | 仅空状态或等待态，注意耗电 |
| `.transition` + spring | Inspector、错误详情和批量任务展开 | 推荐 |
| `redacted` + `ProgressView` | 初次数据载入 | 推荐，优先于第三方 shimmer |

所有动画必须尊重 `accessibilityReduceMotion`。关键状态不得只依赖颜色、动画或声音表达。

### 6.2 Liquid Glass

macOS 26 可使用系统 Liquid Glass，但只做渐进增强：

- 让 `NavigationSplitView`、Toolbar、Sheet 和标准控件使用系统材料。
- 使用 `ToolbarSpacer` 对操作分组，避免手写漂浮工具栏。
- 自定义浮动状态控件才使用 `glassEffect`。
- 相邻自定义玻璃元素放入同一个 `GlassEffectContainer`。
- 需要形态过渡时使用稳定 ID 和 `glassEffectID`。
- 不在 Sidebar 和根窗口后叠加自定义不透明背景或额外模糊层。
- macOS 14/15 必须保留完整、清晰的非玻璃界面。

Liquid Glass 不应成为提高最低系统版本的理由，也不应用来装饰每个状态标签和按钮。

## 7. 第三方动画库

### 7.1 候选表

| 库 | 调研状态 | 适用场景 | 成本与风险 | 建议 |
| --- | --- | --- | --- | --- |
| [Pow](https://github.com/EmergeTools/Pow) | MIT；macOS 12+；仓库 2026 年仍有活动 | `shake`、`ping`、`shine` 等 SwiftUI 状态反馈 | 特效容易过度；最近正式版为 2024 年 `1.0.5` | 一期唯一值得优先试用的动画依赖 |
| [Rive](https://github.com/rive-app/rive-ios) | MIT；支持 AppKit、SwiftUI、macOS；2026 年活跃 | 交互式状态机动画、引导页、品牌空状态 | 增加运行时和设计资产工作流；不适合核心状态 | P2 品牌化时评估 |
| [Lottie](https://github.com/airbnb/lottie-ios) | Apache-2.0；`4.6.1`；2026 年活跃 | 设计师交付的线性矢量动画 | 动画语义较弱、资源体积和渲染需评估 | 可选，不与 Rive 同时引入 |
| [SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer) | MIT；最新正式版 `1.5.1`（2024） | 骨架屏闪烁 | 原生 `redacted` 与 `ProgressView` 已足够；持续闪烁影响专注 | 一期不引入 |

### 7.2 推荐动画方案

一期默认不添加动画依赖。先使用原生 API 完成以下反馈：

- 网络检测：状态图标 `variableColor` 或轻量脉冲。
- Host Key 确认：Sheet 出现与指纹差异高亮。
- 公钥注入：分阶段进度和当前服务器行状态过渡。
- 成功：图标替换、短促缩放或 checkmark symbol effect。
- 失败：错误行展开，必要时单次轻微 shake。
- 批量授权：稳定列表进度，不使用全屏庆祝动画。

只有原生错误反馈不够清楚时再引入 Pow，并限制使用 `shake`、`ping` 等少数语义效果。Rive 和 Lottie 二选一，且放到品牌引导或高质量空状态，不进入 SSH 核心流程。

## 8. 实用组件与工具库

| 库或框架 | 用途 | 建议 |
| --- | --- | --- |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 用户可配置的全局快捷键和录制控件 | P1 推荐；普通菜单快捷键优先用 SwiftUI Commands |
| [SwiftUI Introspect](https://github.com/siteline/swiftui-introspect) | SwiftUI 无法配置的底层 AppKit 属性 | 受控使用；每处都要有系统版本测试 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 非 Mac App Store 分发的签名自动更新 | 如果选择直接分发则推荐 |
| [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) | 大型状态机、依赖注入和测试 | 一期暂不引入；先用 Observation + Actor，复杂度证明确有需要再评估 |
| SF Symbols | 状态、工具栏和菜单图标 | 强烈推荐，不自绘常见图标 |
| Swift Charts | 日志和检测历史统计 | P2 可选，不用于一期核心页面 |

不建议仅为 Keychain、UserDefaults、日志、启动登录或简单依赖注入增加包装库。原生 API可以更清楚地表达安全属性和系统行为。

## 9. 分发与系统权限

### 9.1 推荐分发方式

一期优先考虑 Developer ID 签名、公证和直接分发，原因是 KeyPort 需要：

- 扫描和修改用户的 `~/.ssh`。
- 调用系统 OpenSSH 做兼容性验证。
- 管理用户选择或已有的密钥文件。
- 进行网络连接、CloudKit 和 Keychain 操作。

Mac App Store 沙盒会显著增加文件访问、进程调用和持久授权设计成本。若产品必须进入商店，应先单独做沙盒原型，不应在主体开发完成后再迁移。

### 9.2 权限边界

- 一期不需要 root 权限，不安装特权 Helper。
- 不修改系统级 `/etc/ssh` 配置。
- 不请求 Terminal 自动化权限，不通过 Apple Event 操作 Terminal。
- 所有文件访问限定在 KeyPort 目录、用户明确选择的密钥文件和 `~/.ssh/config`。
- 一期不需要登录启动或常驻后台 Helper。

## 10. 依赖准入规则

任何第三方依赖加入项目前必须满足：

1. 许可证允许商业分发。
2. 支持 Swift Package Manager 和目标 macOS 版本。
3. 最近维护状态、Issue 响应和发布记录可接受。
4. 锁定精确版本并提交 `Package.resolved`。
5. 审查传递依赖、二进制产物和网络行为。
6. 安全核心依赖必须有隔离接口和替换方案。
7. 动画库不得成为业务状态或无障碍体验的唯一实现。

## 11. 一期推荐依赖集合

### 必选原生框架

```text
SwiftUI
AppKit
Observation
Security
LocalAuthentication
CloudKit
SwiftData
CryptoKit
Network
OSLog
UniformTypeIdentifiers
```

### 第三方依赖上限建议

```text
SSH：Citadel（完成技术原型后决定是否采用）
更新：Sparkle（仅直接分发时）
快捷键：KeyboardShortcuts（仅需要全局快捷键时）
动画：Pow（仅原生动画无法满足明确反馈时）
```

一期不建议同时引入 Rive、Lottie、Shimmer、TCA 和多套工具包装库。先让 SSH 授权、安全边界、同步恢复和错误诊断稳定，再增加表现层依赖。

## 12. 开工前决策门

以下结论确认前，不应大规模实现业务页面：

1. 最低 macOS 版本是否接受 14，macOS 26 是否只做渐进增强。
2. Citadel 是否通过 SSH 兼容性与安全原型；失败时是否转向 libssh2 封装。
3. SwiftData + 显式 CloudKit 是否通过双设备同步、删除和冲突原型。
4. iCloud Keychain 密码同步和一次本机验证是否达到近似无感体验。
5. 产品是否采用直接分发；若选择 Mac App Store，先验证沙盒下的 `~/.ssh` 工作流。
6. 一期是否完全不引入动画依赖，只使用 SwiftUI 原生能力。

## 13. 调研来源

- [Apple SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [Apple AppKit Documentation](https://developer.apple.com/documentation/appkit)
- [Apple Security Documentation](https://developer.apple.com/documentation/security)
- [Apple LocalAuthentication Documentation](https://developer.apple.com/documentation/localauthentication)
- [Apple CloudKit Documentation](https://developer.apple.com/documentation/cloudkit)
- [Apple SwiftData Documentation](https://developer.apple.com/documentation/swiftdata)
- [Apple CryptoKit Documentation](https://developer.apple.com/documentation/cryptokit)
- [Apple Network Documentation](https://developer.apple.com/documentation/network)
- [SwiftNIO SSH repository](https://github.com/apple/swift-nio-ssh)
- [Citadel repository](https://github.com/orlandos-nl/Citadel)
- [Pow repository](https://github.com/EmergeTools/Pow)
- [Rive Apple runtime](https://github.com/rive-app/rive-ios)
- [Lottie repository](https://github.com/airbnb/lottie-ios)
- [SwiftUI-Shimmer repository](https://github.com/markiv/SwiftUI-Shimmer)
- [KeyboardShortcuts repository](https://github.com/sindresorhus/KeyboardShortcuts)
- [SwiftUI Introspect repository](https://github.com/siteline/swiftui-introspect)
- [Sparkle repository](https://github.com/sparkle-project/Sparkle)
