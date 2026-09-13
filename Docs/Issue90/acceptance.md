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

## 阶段结论

待用户验收。代码与交互自查已有证据；主页同尺寸对照与原生控件差异尚未获确认，不合并、不关闭 Issue、不进入下一阶段。

## 2026-09-13 真实 App 自查记录

- 已验收：真实独立 macOS App 启动，三栏、详情与表单可交互；App 二进制位于本 worktree 的 `dist/KeyPortDesignPreview.app/Contents/MacOS/KeyPortDesignPreview`。只链接新界面模块，不初始化生产模型。
- 已验收：表单截图 `evidence/native-form.png` 与 `evidence/figma-form.png` 均为 880×740。修正主内容上移及按钮宽度后重新截取。
- 已验收：默认 SecureField；显示后 AX 明确呈现固定 `demo-only`。使用现有密钥移除密码输入，无密码提交只弹出“表单校验通过。此预览未执行网络连接或授权。”。
- 已验收：高级项展开与可编辑别名；端口 0 阻止提交并显示“端口必须为 1–65535。”；长名称输入保持在字段内。Tab 实测：名称→地址→端口→账户→密码，Escape 关闭表单。
- 已验收：缩窄窗口约 1112×760 后三栏及操作仍完整可见，见 `evidence/native-narrow.png`。三种状态通过右上角菜单实际切换；Mac Studio 列表不会随 gl-mt3600 的状态变化。
- 已验收：JetBrains Mono 官方 Regular/Medium 字体及 OFL 随模块资源打包，使用 CoreText 进程级注册，不安装到系统。来源为 JetBrains/JetBrainsMono 的 fonts/ttf 与 OFL.txt。

## 差异与待确认

| 项目 | 结果 | 证据/操作 |
|---|---|---|
| 主页层级、200/320/800 初始栏宽 | 已验收 | `native-home.png`，App 构造窗口为 1320×820，只有一行工具栏 |
| 主页同尺寸像素级对照 | 待用户验收 | computer-use 截图缩为 1237×768，Figma 工具输出为 1024×659 且含阴影；未放大伪装为原尺寸。请用 macOS 截取 App 原窗口，与 Figma 2:2 原尺寸导出核对 |
| 表单内容区与操作位置 | 已验收 | 两张 880×740 图；主要内容 x32/y156/w816/h464、底部操作 y636 |
| 中文与图标 | 待用户验收 | 3:528 明确允许系统中文及 SF Symbols；实际使用苹方/系统符号，外观与 Figma Noto/Lucide 有差别 |
| 原生窗口控制与账户选择器 | 待用户验收 | 系统 traffic lights 靠上，Picker 使用系统控件高度/箭头，尚未得到用户接受，不得把原生默认值当作自动通过 |
| 密码显示位置 | 待用户验收 | 使用宽 100 的可编辑密码字段，显示链接略右于 Figma，保留真实输入及选择行为 |
| 高级项组合 | 已验收 | `native-advanced.png` 为现有密钥+高级展开组合；Figma 19:76 是密码模式+高级展开，布局相同但不是同状态逐像素证据 |
| 长名称主页行与列表选择 | 已验收 | `native-home-long.png` 显示长名称截断且未撑破栏宽；实际选择 Mac Studio 显示 jooder/192.0.2.2，tencent-cloud 显示待添加账户/cloud.example |
| 真实 SSH、iCloud、迁移、Graph | 后续阶段 | 按 #78 门槛暂不接入，不将预览视为生产闭环 |

## 用户复现

1. 运行 `./script/build_design_preview.sh`，或打开本 worktree 的 `dist/KeyPortDesignPreview.app`。这是隔离示例，请勿输入真实密码。
2. 主页右上角“…”选择三个预览状态；核对 2:2、3:170、3:341 的层级、留白、按钮、字体与状态。
3. 点击列表“+”打开单表单；对照 16:2，测试显示/隐藏、现有密钥、高级项、Tab、Escape。
4. 待确认：原生窗口控制/Picker 是否符合批准设计，以及 1320×820 原尺寸截图的差异。未收到明确验收前，不合并、不关闭 #90、不进入第二阶段。

## 检查结果

- `./script/test.sh` 首次：KeyPortTests 193 个中 1 个失败，ProcessExecutorTests.testExitStatusAndSeparatedOutputAreCaptured 意外报告 timedOut；该文件未修改。独立复跑通过。
- `./script/test.sh` 完整复跑退出 0：KeyPortTests 193/193、KeyPortCoreTests 312/312、新界面测试 2/2；CoreChecks、SSH relay IPv4/IPv6 fixture、AskPass FIFO 检查通过。
- 最后主页 fixture 调整后重新构建并启动；表单测试再次通过。`git diff --check` 通过。
- 真实服务器、用户 SSH 配置、钥匙串、CloudKit 未作为测试目标。

## 确切运行版本

- 实现/构建 commit：`608b34867f5bd666438148ce08f6f6fbb9838f2d`。
- App：`/Users/joo00der/.codex/worktrees/7de9/key-port/dist/KeyPortDesignPreview.app`。
- 提交后执行 `./script/build_design_preview.sh`，构建 3.44 秒，ad-hoc codesign 严格验证成功；PID 98371 的 argv 指向上述 App。
- 随后 computer-use 读取真实窗口标题“KeyPort · 隔离设计预览”，AX 包含三栏内容、状态、主页操作及系统窗口按钮。
- `native-home.png`、`native-form.png` 和变体是实现过程真实运行截图；此前校验/窄窗口截图保留相应中间版本，不宣称全部逐像素对应此 commit。最终源码变化包括独立示例详情及公网标签。
