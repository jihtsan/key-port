# Issue #94：SSH 别名与中文描述验收

阶段结论：**功能自验已通过；原生视觉仍待用户验收。保持堆叠草稿，不合并，不关闭 #78/#90/#92/#94。**

本次命名设计已经用户确认。此前 #90 的主页原尺度/系统字形、#92 的新增失败/取消页等视觉例外没有因此获得确认。

## 构建与证据

- 依赖 PR #93：`codex/issue-92-first-access-flow`，开始前 fetch 核实 head `4ddc60a3dbf933d0de3d16dc995a75dd60e6b2b5`。
- 本阶段分支：`codex/issue-94-ssh-alias-description`；PR base 为上述依赖分支，未混入前置 diff。
- **最终源码 commit：`1c0890252361f79d5de331e4a2ff4d11036f0ab1`。** 后续提交只添加本文和证据。
- **App：`/Users/joo00der/.codex/worktrees/8ea3/key-port/dist/KeyPortDesignPreview.app`**。
- 构建：`./script/build_design_preview.sh`；独立 bundle、ad-hoc 签名；`codesign --verify --deep --strict` 成功；实际运行进程路径与上述 App 一致。
- 可执行文件 SHA-256：`54880dbda0f366f1952b9040ca8627d50b7ce1fe9bcc014d39e40043d0821d26`。
- [最终证据目录](evidence/1c08902)：49 组截图与对应 AX、测试日志、构建日志、交互轨迹。[manifest.json](evidence/1c08902/manifest.json) 记录截图原始尺寸、文件哈希及完整 App 文件哈希。
- 最终源码 `swift test --filter KeyPortInterfaceTests`：**25/25 通过**，包含表单 7 项、首次访问 18 项；`git diff --check` 通过。日志里其他 target 的 0 selected tests 不表示生产套件通过，本次未重跑生产全量测试。

## 设计读取与差异

通过实际 `get_design_context` 读取 Figma 文件 `RGpDDMdxvoPwzhlTB5RyiY` 的 26:2、27:2、27:177、27:198、27:234、27:270、28:2，加载 Figma design-to-code、SwiftUI、macOS build-run-debug、Computer Use 技能。仓库没有额外跟踪的 AGENTS.md，遵循用户提供及本机全局 GitHub 流程。

[Figma 参考导出](evidence/figma) 与本次原生证据分开保存。没有修改 Figma，也没有把历史节点名称中的“待确认”当作未授权。

| 设计节点 | 实现与差异 | 结论 |
|---|---|---|
| 26:2 表单 | 880×740，外边距 32、面板 816×464；主内容间距 10，行高 48、输入高 40，标签宽 120/间距 20。别名、规则、描述、地址/端口、账户、密码依次排列；删除名称与高级别名入口 | 结构/交互已验收；原生字形观感待用户验收 |
| 26:2 初始值 | 新建别名留空，仅提示 `例如 home-router`，由用户显式输入并提交；现有 home-router fixture 已占用，所以成功路径输入 home-router-2。不会静默使用建议值 | 已验收；这是示例数据差异，不是自动改名 |
| 27:198 格式错误 | 红色输入边框、规则位置内联错误、主按钮 45% 不透明度且禁用；其他字段不清空 | 已验收，alias-invalid |
| 27:234 重复别名 | home-router 显示现有 SSH 配置冲突；MAC-STUDIO 显示已管理条目冲突；均禁用提交并保留输入 | 已验收，alias-config-conflict / alias-managed-conflict |
| 27:270 现有密钥/空描述 | 不显示密码字段，不需要密码；描述为空保留输入提示。认证方式文字使用系统字体 | 已验收，existing-key-empty-description；辅助文案延续前置“优先使用本机已有密钥认证” |
| 27:2 主页 | 别名主标题、中文描述副标题；mac-studio 无描述时无副标题；搜索提示与匹配覆盖两字段；连接设置摘要改为描述、地址策略 | 结构/交互已验收；原尺度与整体字形待用户验收 |
| 27:177 成功 | 别名 22/33 技术标题，描述系统 14 点；命令 17/26；空描述移除整行，长描述最多两行并保留完整 help | 已验收，success-description / success-empty-description / success-long-description |
| 28:2 规则 | 名称改为 description，alias 单一来源；修改描述/地址不改变命令与设备+服务器账户身份；历史名称映射独立 | 已验收（状态与样本测试） |
| 前置图标/字体 | 复用 #90 依据 3:528 的系统中文、SF Symbols 与已打包 JetBrains Mono；图标未在本阶段重画或替换 | 字形/抗锯齿与 Figma Noto/Lucide 有差异，沿用待用户验收边界 |
| 预览说明 | 页脚保留隔离演示和手动场景控制，成功加“模拟”；不显示“待确认设计”历史文案 | 明确模拟边界；原生整体视觉待用户验收 |

## 逐项功能与原生交互

证据列为目录内同名 `.jpg`、`.ax.txt`；模型测试的边界单独标注，不冒充视觉验收。

| 验收项 | 结论 | 证据 |
|---|---|---|
| 别名必填、非法值、无重复入口 | 已验收 | alias-required、alias-invalid、form-password-hidden；模型覆盖空白、首位数字/-/_、点、通配符、非 ASCII、前后空白 |
| 已管理及已有配置来源冲突、大小写策略 | 已验收 | alias-config-conflict、alias-managed-conflict；输入未改写、按钮禁用 |
| 编辑自身不误报，其他条目仍冲突 | 已验收（测试） | `testBothDirectorySourcesAndEditingOnlyOwnEntry`、`testEditingOwnStoredAliasDoesNotBlockAccessOrRenameLegacyAlias`；真实生产编辑入口尚未接入 |
| 描述中文/空/长、两字段搜索 | 已验收 | home-ready、home-empty-description、home-long-description、search-description、search-alias、success-empty-description、success-long-description |
| 窄窗口长说明 | 已验收（可见性） | home-narrow-long-description；操作与命令区不被说明挤压；不宣称像素级一致 |
| 密码隐藏/显示、地址校验回归 | 已验收 | form-password-hidden、form-password-shown、invalid-address；仅使用固定 demo-only，未输入真实凭据 |
| 一次填写与连续流程 | 已验收 | host-confirmation、login、authorization、verification、success-description；确认后按模拟返回推进，不靠定时器成功 |
| 取消/返回保留别名描述，密码清空 | 已验收 | host-cancel-preserves-alias、login-cancel-preserves-alias、authorization-cancelled、cancel-return-form、verification-cancelled、reopened-password-cleared、form-cancel-reopen |
| 描述/地址改动不改别名或授权 | 已验收 | failure-partial-success → partial-edit-description-address → retry-skips-install → success-description-address-edited；从登录直接到验证，命令仍 ssh home-router-2；身份维度另有测试 |
| 全部失败类型与部分成功 | 已验收（模拟行为） | failure-unreachable、failure-identity-mismatch、failure-login、failure-authorization、failure-authorization-unknown、failure-partial-success；不匹配无继续/重试按钮 |
| 未知结果安全重试 | 已验收 | unknown-retry-skips-install；重新核对已有授权，没有重复安装等待 |
| 迟到回调、设备/账户/服务器隔离 | 已验收（状态测试） | 各步骤非合作回调、迟到安装、关闭时迟到交接、账户/设备/服务器维度测试继续通过 |
| 成功与终端/复制同一别名 | 已验收 | success-description、terminal-pending、terminal-feedback、copy-feedback；测试断言两个适配调用接收相同 command |
| 终端/复制失败恢复 | 已验收 | terminal-unavailable、copy-failed、copy-recovered；保留 success，不重跑授权；未触发真实终端或剪贴板 |
| 键盘与 AX | 已验收 | Cmd+N、Escape 实际使用；keyboard-alias-to-description 显示 Tab 选中描述内容；错误/成功/各主要状态有 AX |
| 原尺度、系统字体整体观感 | 待用户验收 | 下面的尺度限制和用户操作路径 |

## 冲突和迁移边界

- `AliasDirectory` 是显式注入的快照。fixture 包含 home-router（SSH 配置来源）、mac-studio 与 tencent-cloud（管理来源），不读取、解析或修改用户真实 SSH 配置。
- 新建规则是本产品规则：`[A-Za-z][A-Za-z0-9_-]*`。不是 OpenSSH 所有合法 Host 值的定义。空白不自动 trim，大小写不自动改写；冲突比较忽略 ASCII 大小写。
- ownerID 是稳定条目 ID；管理条目与它生成的配置条目可共享 ownerID。编辑自身只排除这个 ID；不属于自身的配置仍冲突。历史别名仅在管理目录证明属于该条目、且输入与存量字符串相同时豁免新建格式规则。
- `ServerNaming.legacy` 逐项保留 ID、原 SSH 别名、旧展示名称→description。测试样本：我的服务器→legacy.host、🔑→123-old、空说明→Mixed_CASE、缺别名→仍缺别名；空别名不会被伪造为可连接的新别名，后续需人工补齐。
- 此兼容映射不声称验证全部 OpenSSH 模式/Include/Match/通配符或完成生产迁移。真实接入时需要从生产模型投影完整目录、原子保留别名、防止检查与写入竞争、处理旧模式条目、备份与往返迁移验证。
- `FirstAccessFlow` 提交也检查注入目录，不能绕开表单校验；本阶段没有真实持久化或并发写入。成功预览仍不把新服务器写回生产详情或配置。

## 文件处置矩阵（继承 #90）

| 文件/入口 | 本阶段处置 | 后续边界 |
|---|---|---|
| KeyPortInterface/AccessFormDraft.swift | 删除 name、suggestedAlias、resolvedAlias、CryptoKit hash；仅 alias + description | 生产草稿在真实接入阶段映射 |
| KeyPortInterface/AccessFormView.swift | 删除 advanced 状态及第二别名输入，校验/恢复复用单表单 | 不新增平行生产入口 |
| KeyPortInterface/AliasDirectory.swift | 新增目录、命名展示/无损兼容投影 | 未执行生产数据迁移 |
| KeyPortInterface/FirstAccessFlow.swift、FirstAccessView.swift | 共用固定 alias，恢复保留 description；保留原取消/重试代际隔离 | 原真实适配边界不变 |
| KeyPortInterface/ServerHomeView.swift | 独立 alias/description fixture、两字段搜索、空说明隐藏 | 真实列表数据源及“连接设置”编辑仍属后续集成 |
| KeyPortDesignPreview/FixtureAccessAdapter.swift | 注入隔离目录、返回非敏感表单草稿 | 不接 SSH/终端/剪贴板/钥匙串/CloudKit |
| KeyPort/Features/Servers/ServerAccessFormView.swift、旧列表与 Graph 详情、AppModel | 本阶段未修改；沿用 #90 替换矩阵登记 | 真实接入阶段迁移旧名称及表单并删除旧入口，不批量改生产层 |

## 尺度与剩余用户确认

原生图片直接保存 `sky.get_app_state` 返回的 JPEG 原始字节，没有裁切、放大、重采样或格式转换。Figma 主页 1× 导出为 1400×900（含 1320×820 frame 外阴影），原生主页工具返回 1237×768；窄窗口工具返回 1152×768。表单及流程图返回 880×740，已按控件位置和可见性自验。工具没有原始像素/缩放参数，不能用放大后的缩图冒充一致尺度证据。

请打开上述确切 App：

1. 主页核对 alias/中文说明层级、原生中文/技术字形；“…”可切换长说明和三种状态。与 Figma 27:2 对照原尺度观感。
2. Cmd+N 打开表单；使用 home-router-2（home-router 在 fixture 中已占用），中文说明选填，可选现有密钥免密码。提交后核对主机确认，逐次点击右下“模拟完成”到成功。核对 26:2、27:177 的原生视觉。
3. 本次功能已自验，需实际答复的是整体原生观感及 #90/#92 遗留的原尺度/新增错误与取消页视觉例外。用户尚未答复前保持“待用户验收”，不以等待超时为通过，不合并前置或本 PR。

没有已知未修复的本阶段功能失败；真实 SSH、生产编辑/持久化迁移、Graph、钥匙串与 CloudKit 均未进入本阶段。
