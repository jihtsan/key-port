## JODER-43 服务器详情页视觉与交互验收

关联需求：[JODER-36](mention://issue/84d55d5c-da8e-4455-a3ec-a3603c2d55a4)、[JODER-41](mention://issue/06b77723-04b4-4208-b91c-6a2b531e09fa)；验收对象为 GitHub PR #8、commit `deda3e264f14035818e37af8732d37239248de82`。

## 结论

**退回修改。** 已确认 3 项阻断级实现偏差，且宿主权限和真实 fixtures 不足，无法完成截图、VoiceOver、Full Keyboard Access、深色模式及全部边界状态的独立实机验收。未观察到的状态不判定通过。

## 设计目标与用户场景

目标用户在 macOS KeyPort 的服务器列表中选择 SSH 账户后，应在右侧首屏快速确认账户身份、最近免密验证结论和下一步操作，并直接完成两类测试及两种复制。低频安全证据、连接配置、关联信息和运维入口按已确认层级继续可达。

当前入口和主路径为：启动 KeyPort -> 侧边栏“服务器” -> 内容列选择账户 -> 右侧查看“账户摘要 / SSH 访问” -> 测试或复制 -> 展开安全详情 -> 向下查看配置、关联和运维能力。可观察反馈包括综合状态、状态主 CTA、测试进度/结果、复制成功、Host Key 风险和凭据弹窗。

## 已确认结构与视觉方向

页面顺序必须为：

1. 账户摘要
2. 认证与快速访问
3. 验证与安全详情
4. SSH 账户与连接配置
5. 关联信息（设备、Test Case）
6. 运维与远端管理（机器配置、远端授权）

沿用现有 macOS SwiftUI 组件、系统语义色和 SF Symbols；内容列保持高密度、可扫描，不新增装饰主题。测试按钮固定使用 `key.horizontal` 和 `lock.open`。状态使用图标和文案共同表达，复制反馈原位、非阻塞，并提供 VoiceOver announcement。

## 阻断问题

### 1. 整页顺序仍不符合已确认信息架构

- 场景：用户从安全详情继续向下查找连接配置、关联和运维能力。
- 预期：安全详情后先出现 SSH 账户与连接配置，再出现关联信息，最后出现机器配置与远端授权；失败/操作日志收进安全详情。
- 实际：`Sources/KeyPort/Features/Servers/ServerDetailView.swift:29` 的顺序是操作日志、安全详情、设备关联、Test Case、机器配置、连接资料、远端授权；`sshOperationLog` 在 `:168` 作为独立 `GroupBox`，不在安全详情内。
- 影响：连接配置被埋到关联和运维动作之后，机器配置与远端授权被连接资料拆开；验收标准 1、4 未满足。

### 2. Host Key 风险和指纹仍可被折叠隐藏

- 场景：Host Key 待确认或发生变化，用户查看旧指纹和本次观察到的新指纹。
- 预期：风险状态自动展开，且风险和指纹在问题解决前持续可见，不能被折叠状态掩盖。
- 实际：安全区直接绑定可写的 `securityDetailsExpanded`（`ServerDetailView.swift:193`）；`:700` 只在出现/状态变化时把它设为 `true`，用户随后仍可折叠。切换到另一个相同风险状态账户也没有以 `server.id` 触发展开。
- 影响：新旧指纹和确认入口可能再次隐藏，验收标准 4 及安全可见性要求未满足。

### 3. 内容列复制缺少成功反馈和 VoiceOver announcement

- 场景：用户在约 300pt 内容列点击账户行末尾的常驻复制按钮。
- 预期：只复制纯别名；按钮原位短暂显示 `checkmark`，约 1.5-2 秒恢复，并宣布复制成功。
- 实际：`Sources/KeyPort/Features/Servers/ServerListView.swift:161` 直接调用复制闭包，按钮始终是 `doc.on.doc`，仅有 tooltip 和静态 accessibility label，没有成功 value 或 announcement。详情区在 `ServerDetailView.swift:674` 已实现所需反馈，内容列未复用。
- 影响：鼠标和辅助技术用户都无法确认内容列复制是否成功，验收标准 12 及 Issue 明确的复制反馈要求未满足。

## 已验证范围

- `./script/build_and_run.sh --verify`：通过；PR #8 对应 SwiftPM app bundle 构建、ad-hoc 签名、启动和进程检查成功。
- `./script/test.sh`：通过；30 项 XCTest、`KeyPortCoreChecks` 和 `KeyPortAskPassChecks` 全部成功。
- `codesign --verify --deep --strict --verbose=2 dist/KeyPort.app`：通过；当前为 ad-hoc 签名，`TeamIdentifier=not set`。
- 源码确认：两个测试按钮使用指定 SF Symbols；详情复制实现 1.8 秒原位反馈和 announcement；内容列状态与复制按钮采用固定尺寸；24 小时节流、连接身份失效、网络失败保留历史成功和两种复制字面值有核心测试。

## 未验证范围与证据限制

- Computer Use 可正常读取 Finder，但读取 KeyPort 时 native pipe 在返回前关闭；唯一 bundle 标识的 review-only 副本结果相同。
- CoreGraphics 能确认 KeyPort 窗口存在及尺寸，但 `screencapture -l` 被宿主 Screen Recording 权限拒绝，无法生成可审阅 PNG。
- 本机现有非敏感摘要仅覆盖 3 个已授权单账户，未覆盖多账户、长别名及所需错误状态；未替换真实快照、SSH 或 Keychain 数据。
- 因此未验证 980x620 / 1180x760 / 1440x900 的整页像素表现、300pt 多账户长别名、无密码、Host Key 待确认/变化、测试中、网络失败、公钥拒绝、本地密钥异常、tooltip 实际呈现、Full Keyboard Access、VoiceOver label/value/announcement、深色模式和系统语义色。
- 新增测试只覆盖核心策略和复制字符串，没有覆盖整页状态映射、安全区展开规则、内容列复制反馈或响应式 UI；验收标准 14、15 尚未闭环。

## 开发交接

1. 将 `connectionDetails` 移到安全详情之后、关联信息之前；将 `machineConfiguration` 与 `remoteAuthorizations` 连续放在最后的运维区域；把 `sshOperationLog` 合并进“验证与安全详情”。
2. Host Key 风险期间使用不可折叠的风险详情，或用强制展开 binding 阻止关闭；同时监听 `server.id`，确保切换风险账户时仍展开并展示新旧指纹。
3. 为内容列复制增加按账户区分的临时成功状态、原位 `checkmark`、1.5-2 秒恢复和 `AccessibilityNotification.Announcement`；继续只复制纯别名，并保持整行选择与按钮命中区分离。
4. 补齐可重复的非敏感 UI fixtures / UI 测试，覆盖完整状态映射、展开规则、复制反馈和三种窗口尺寸；修复后在具备 Screen Recording 和辅助功能验证条件的宿主提供整页截图或录屏，再进行独立复验。

非目标：不改变 SSH 授权业务规则、24 小时检测策略、全局视觉主题或既有设备/Test Case/远端授权能力。

本次未修改生产代码，无需新 PR；新增本验收文档作为设计与复验基线。
