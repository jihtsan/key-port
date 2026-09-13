# Issue #90 第一切片验收

基准：Figma RGpDDMdxvoPwzhlTB5RyiY，2:2、3:170、3:341、3:528、16:2、19:2、19:39、19:76；2026-09-13 通过真实 get_design_context 读取。父任务 #78 重启评论 5653566128。

## 文件级处置矩阵

| 文件 | 决策与阶段 | 理由 |
|---|---|---|
| Sources/KeyPort/App/KeyPortApp.swift | 保留至真实接入阶段，然后迁移入口 | 当前启动初始化生产 AppModel、设备标识及 tunnelRegistry，不适合 fixture |
| Sources/KeyPort/App/ContentView.swift | 后续替换 | 旧 NavigationSplitView 与多 sheet 状态依赖 AppModel；第一切片不复用其层级 |
| Sources/KeyPort/App/AppSidebarView.swift | 后续替换 | 新主页侧栏按 Figma 收敛 |
| Sources/KeyPort/Features/Servers/ServerWorkspaceView.swift | 后续替换 | 生产列表与发现入口在真实接入时迁移 |
| Sources/KeyPort/Features/Servers/ServerListView.swift | 后续替换 | 列表表现迁移至新界面，发现逻辑接入适配层 |
| Sources/KeyPort/Features/Servers/ServerAccessFormView.swift | 后续迁移并删除旧视图 | 保留真实授权流程至第二、三阶段；新表单不调用模拟网络结果 |
| Sources/KeyPort/Features/Graph/NodeWorkspaceDetailView.swift | 后续删除 | 新详情不采用旧大块 SSH/路径堆叠 |
| Sources/KeyPort/Features/Graph/NodeWorkspaceHeader.swift | 后续删除 | 新身份区替换 |
| Sources/KeyPort/Features/Graph/NodeWorkspaceAccountsSection.swift | 后续迁移 | 授权操作移入独立页面后删除旧容器 |
| Sources/KeyPort/Features/Graph/NodeWorkspaceSSHAccountsSection.swift | 后续迁移 | 账户管理移入新页面后删除旧容器 |
| Sources/KeyPort/Features/Graph/NodeWorkspaceRoutesSection.swift | 后续迁移 | 地址管理移入新页面后删除旧容器 |
| Sources/KeyPort/Features/Graph/NodeWorkspacePresentation.swift | 审计后迁移投影 | 新界面状态不能依赖旧 View 层级 |
| Sources/KeyPort/Stores/AppModel.swift | 保留，第三阶段提取适配层 | 当前真实业务编排，本阶段不初始化 |
| Sources/KeyPort/Services/SSH/TrustedSSHSession.swift | 保留复用候选 | 实际 Host Key/SSH 边界；本阶段不运行 |
| Sources/KeyPort/Services/SSH/SSHService.swift | 保留复用候选 | 实际授权服务；本阶段不运行 |
| Sources/KeyPort/Services/CloudSync/CloudV2SyncService.swift | 保留复用候选 | 同步元数据；本阶段不运行 |
| Sources/KeyPortInterface/AccessFormDraft.swift | 新建可复用表单模型 | 无持久化与服务依赖 |
| Sources/KeyPortInterface/AccessFormView.swift | 新建新应用层表单 | 状态独立、提交回调与服务分离 |
| Sources/KeyPortInterface/ServerHomeView.swift | 新建第一切片主页 | 仅隔离 fixture；第三阶段拆出数据适配注入 |
| Sources/KeyPortInterface/InterfaceStyle.swift | 新建统一视觉定义 | 原有视图无对应 token，按 Figma 3:528 |
| Sources/KeyPortDesignPreview/PreviewApp.swift | 临时独立预览入口 | 不依赖 KeyPort 生产 target；最终生产入口迁移后删除 |
| script/build_design_preview.sh | 临时预览构建入口 | 独立 bundle ID，无 CloudKit、SSH helpers、生产生命周期 |

本阶段没有被新入口接管的生产实现，故未删除生产视图。不得将上述后续清理标为完成；最终不得长期保留双 UI。

## 阶段结论（2026-09-13 复核修复后）

**待用户验收**。#90 评论 5653681184 指出的地址校验与提示返回错误已修复并通过真实 UI 回归。可确认的布局差异已修复；仍不合并 PR #91、不关闭 #90、不进入 Graph 或真实授权。

## 唯一最终构建与证据

- 实现/构建 commit：`1148b12cdb60b640b231fbe4b2b63df65f3c1f98`。之后的提交只更新本文及证据，不改变构建源码。
- App：`/Users/joo00der/.codex/worktrees/7de9/key-port/dist/KeyPortDesignPreview.app`。
- 从该提交运行 `./script/build_design_preview.sh`；构建成功，ad-hoc codesign 验证成功；真实窗口由 computer-use 操作确认。
- **所有最终原生截图及对应 AX 文本均在 [evidence/1148b12](evidence/1148b12)**。清单、SHA-256、原始图像尺寸见 [manifest.json](evidence/1148b12/manifest.json)。文件保留工具返回的 JPEG 原始字节，未放大、重采样或转换。
- 前一版及中间版原生截图已从当前目录删除，不能作为本版本验收证据。Figma 参考图仍保留。

## 逐项验收

| 环节 | 结论 | 最终构建证据 |
|---|---|---|
| 真实设计读取 | 已验收 | 2:2、3:170、3:341、3:528、16:2、19:2、19:39、19:76 已读取实际 design context |
| 隔离 App 构建启动 | 已验收 | 独立 executable 仅链接 KeyPortInterface，无生产 AppModel、Keychain、CloudKit、SSH 初始化 |
| 主页三状态 | 已验收（结构/文案/交互） | home-ready、home-unconfigured、home-unreachable，均有 JPG 与 AX；菜单实际切换 |
| 密码默认隐藏/显示 | 已验收 | form-hidden / form-shown；固定 demo-only，SecureField 与明文 TextField 实际切换 |
| 现有密钥不强制密码 | 已验收 | form-existing-key / existing-key-valid；无密码提交仅提示校验通过，不产生授权结果 |
| 高级别名 | 已验收 | form-advanced-password；与 Figma 19:76 一样为密码模式+高级展开；输入起点修正为 x112 |
| 无效地址拒绝且保留输入 | 已验收 | form-invalid-address；!!! 被拒绝，名称/账户/密码/地址均保留供修正 |
| 合法 IPv6 | 已验收 | ipv6-valid；2001:db8::1 实际提交通过；IPv4/DNS/IPv6 其它边界由回归测试验证 |
| 提示返回状态 | 已验收 | form-after-success；关闭提示后地址保留、密码清空、无必填错误。再次主动提交才校验空密码 |
| 长名称与窄窗口 | 已验收 | home-long-name / home-narrow-long；1112×760 原生截图，名称截断且主要操作不溢出 |
| 输入 Tab / Escape | 已验收 | 首轮实际检查：名称→地址→端口→账户→密码；本轮 Escape 多次关闭表单并重新打开，行为保持 |
| 主页原尺寸像素级一致 | 待用户验收 | 详见尺寸限制，不把缩图当作原尺寸证据 |
| 中文/系统图标整体视觉 | 待用户验收 | 3:528 允许系统中文与 SF Symbols；需用户确认最终原生观感 |

## 本轮修复和差异表

| 项目 | Figma 基准 | 最终实现与检查 |
|---|---|---|
| 窗口按钮 | 56 高标题区，居中布置 | AppKit 保留系统按钮及关闭/缩小/缩放行为，layout 时重设父区 56 高与按钮位置；截图已确认不再紧贴顶边 |
| 账户选择器 | 142×30，白底、边框、右箭头 | 改为原生 Menu + 自定义按钮外观，142×30、5 圆角、#D7DCE3 边框；默认 borderless 样式会丢弃布局，已改 button/plain 并真实验证 |
| 密码显示链接 | 约 x304 | 密码编辑区由 100 调整为 84，加 12 间距，链接 x304；实际截图已核对 |
| 高级别名 | 约 x112 | 标签宽 44、间距 12，输入由 x196 改为 x112；密码模式截图已重新取得 |
| 主表单 | 880×740；内容 x32/y156/816×464；操作 y636 | 原始截图 880×740，纵向位置和主操作宽 137/取消宽 112 保持对齐 |
| 技术字体 | JetBrains Mono | 官方 Regular/Medium 字体和 OFL 随模块打包，CoreText 进程级注册；不安装系统字体 |
| 中文与图标字形 | 设计以 Noto/Lucide 代替原生 | 按 3:528 使用系统中文与 SF Symbols，存在字形/抗锯齿差异；不是未经尝试的布局例外 |
| 密码掩码 | Figma 静态 10 个点，但显示示例 demo-only 为 9 字符 | 原生 SecureField 如实掩码 9 字符，未为模仿静态图伪造密码长度 |

### 地址语法与提交边界

IPv4 使用系统 inet_pton 并要求四段、无歧义前导零；IPv6 使用 inet_pton，允许括号与合法 scope 标识；DNS 允许单段名称、连字符、多个标签、结尾点及 punycode，标签最长 63、总长最多 253。拒绝 !!!、越界/残缺 IPv4、错误 IPv6、协议/账户/端口混入、空标签、非法字符。Unicode 域名需使用 punycode。此处只检查语法，不做 DNS 查询、不证明可达性或主机身份。

错误属于提交尝试，编辑会清除旧提示；有效提交复制当次值给回调后立即清空本地密码，不持久化。关闭预览成功提示不会对清空后的密码自动重新校验。

## 尺寸限制与尝试记录

1. 已用 Figma download_assets 明确 defaultScale=1 重新导出主页，原文件 [figma-home-1x.png](evidence/figma-home-1x.png) 为 **1400×900**，包含设计 frame 1320×820 之外的阴影边界。不是旧的 1024×659 缩图。
2. 原生初始 window contentRect 为 **1320×820**；sidebar=200、list=320、detail=800、toolbar=56、detail padding=32。Computer Use 的 get_app_state 原始返回图仍为 **1237×768 JPEG**。该受支持 API 只有 app/disableDiff，没有请求原始分辨率或缩放系数的参数。未借助不受支持的截图接口或放大图片伪装原尺寸。
3. 表单 get_app_state 返回 **880×740 JPEG**，与 Figma 表单 PNG 同尺寸，可直接对照。窄窗口实际返回 1112×760，无额外放大。
4. 仍无法自行确认的只有主页原始尺度的像素差异及最终原生字形观感。请用户用系统窗口截图与 Figma 1× 导出核对，或明确接受按参数与现有缩图完成视觉验收。用户未确认前保持待验收。

## 验证结果

- 最终 commit `swift test --filter AccessFormDraftTests`：4/4 通过。覆盖有效 IPv4/IPv6/DNS、非法边界、输入保留、成功清空密码而不产生错误、再次提交与现有密钥分支。
- 本轮测试曾发现 Darwin inet_pton 接受 IPv4 前导零，已补四段前导零检查并重跑通过，未忽略失败。
- 最终 commit `./script/build_design_preview.sh`：构建 2.84 秒、签名验证/启动通过；之后真实 UI 证据如上。
- 上一轮完整 `./script/test.sh` 复跑退出 0：KeyPortTests 193/193、KeyPortCoreTests 312/312、CoreChecks、SSH relay IPv4/IPv6 fixture、AskPass FIFO 通过。首次原有 ProcessExecutor 退出状态测试偶发失败、独立和全量复跑通过的记录保留；本轮未重复宣称全量测试覆盖新变更。
- 本轮修改只在独立界面/预览入口与相关测试；最终 `git diff --check` 通过。

## 用户复现与剩余确认

1. 打开上述 App；主页“…”切换免密就绪/未配置/不可达及长名称，核对布局与原生字形。
2. 点击“+”，先将地址设为 !!! 并提交，应留在原表单并显示地址错误；换回有效地址后提交，关闭提示应保留表单且不出现密码必填错误。
3. 核对显示/隐藏、现有密钥、高级展开；密码模式高级项应在 x112 开始编辑别名。
4. 仅请确认主页原尺度截图差异与整体原生视觉。校验修复和可修复控件位置已自行确认，不再作为用户代测事项。

仍不合并、不关闭 #90、不进入下一阶段。预览按钮不连接真实服务器，不执行真实授权。
