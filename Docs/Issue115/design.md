# Figma 交互设计索引

[需求](requirements.md) · [验收](acceptance.md) · [Issue #115](https://github.com/jihtsan/key-port/issues/115)

## 设计范围与基线

沿用现有 [设置 v2](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=54-2) 的浅色分组表单、圆角卡片及蓝色主操作；双向授予与撤销使用带文字解释的红色按钮。新增独立页面，不覆盖已有设计。

代码使用系统字体及 JetBrains Mono；现有设计使用 Noto Sans SC。本轮 Figma 的 SF Pro 拉丁字形实际渲染为空，已统一使用现有 Noto Sans SC 并重新检查截图。实现仍使用原生系统字体，需要单独做字体与布局验收。此次是可编辑界面提案，不交付独立组件库；当前文件未发现 KeyPort 发布组件、变量或样式。

## 界面与需求映射

| 界面 | Figma | 覆盖需求 | 截图 |
| --- | --- | --- | --- |
| 01 我的设备 | [61:3](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-3) | D1–D8 | [PNG](evidence/01-my-devices.png) |
| 02 新 Mac 设置免密 | [61:4](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-4) | C、F | [PNG](evidence/02-new-mac.png) |
| 03 双向免密确认 | [61:5](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-5) | R、默认别名覆盖 | [PNG](evidence/03-confirm.png) |
| 04 双向验证结果 | [61:6](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-6) | S、独立方向 | [PNG](evidence/04-success.png) |
| 05 反向失败与恢复 | [61:7](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-7) | 部分完成、重试、撤销 | [PNG](evidence/05-partial-failure.png) |
| 06 撤销反向授权 | [61:8](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-8) | S、范围及身份验证 | [PNG](evidence/06-revoke.png) |
| 07 保存登录凭据 | [61:9](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-9) | C、手输与同步选择 | [PNG](evidence/07-credentials.png) |

## 交互契约

- 我的设备 → 添加登录凭据 → 保存/取消；保存成功后更新凭据状态，不展示明文密码。
- 新 Mac 设置免密 → 主机身份核验 → 安装 → 实际验证；缺失凭据进入更新面板。
- 正向验证成功 → 红色开启双向免密 → 可编辑默认别名 → 确认 → 分步执行 → 成功或部分失败。
- 部分失败 → 修改地址并重试，或撤销已安装授权；“稍后处理”保留当前分步状态。
- 已就绪 → 核对公钥、测试连接或撤销；三个动作不混为一谈。
- 红色确认默认不获得键盘焦点；Escape 取消。运行时禁用重复提交并显示当前步骤。
- 字段采用真实可编辑控件，支持键盘顺序、复制和完整值展示。别名冲突错误贴近字段，保留输入，不静默改名。
- 字段校验和系统权限对话框由实现提供；Figma 静态文本不是已经可输入的原生控件。

## 版式与视觉验收边界

画板宽 680，展示完整内容。原生实现使用可滚动内容区，在 640 高窗口及系统大字体下保持全部字段和操作可达；不能照搬 983 高全内容画板为固定不可滚动窗口。表单/卡片采用 auto-layout，避免长地址挤压。

截图仅证明设计内容与排版。尚需真实 macOS 运行中验证窗口尺寸、滚动、焦点、密码控件、VoiceOver、对话框与交互；SSH/iCloud 能力按 requirements.md 和 acceptance.md 另行验收。

## 设计检查记录

2026-09-15：逐张查看七个导出 PNG，标题、账号、地址、别名、按钮和密码掩码均可见；文本几何检查无零宽文本或父容器越界。画板按三列排布，无互相覆盖。8 条按钮导航已配置并读回，用于部分路径演示；确认跳转成功页仅为模拟，不执行 SSH。失败画板可直接打开，文本输入、取消后的状态还原、系统身份验证和异步运行尚不是可操作原型。
