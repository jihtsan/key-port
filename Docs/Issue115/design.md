# Figma 交互设计索引

[需求](requirements.md) · [验收](acceptance.md) · [修订 Issue #117](https://github.com/jihtsan/key-port/issues/117)

## 页面职责

| 页面 | 内容 | 唯一数据来源 |
| --- | --- | --- |
| 我的设备 | 本机名称、默认别名、连接方式、登录凭据摘要和远程登录状态 | 当前 Mac 配置 |
| 编辑本机登录凭据 | 账户与密码的唯一编辑入口 | 同一份设备账户凭据 |
| 配置连接方式 | 可选公网 IP / 域名、Tailscale、局域网 | 本机候选地址及默认方式 |
| 服务器详情 | 当前服务器与本机的两向授权状态、双向按钮、核对、测试、撤销 | 当前选中服务器、账户和当前 Mac 的关系 |

我的设备不列“谁可以登录此 Mac”，不放任何具体服务器卡片或双向免密按钮。已保存本机凭据只展示摘要与“编辑登录凭据”，上方不再重复设置账户或证书。示例服务器名称全部由真实选中对象替换；“东京开发机”与先前 VPS1/VPS2 都不是固定项目。

## 设计基线

沿用 [设置 v2](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=54-2) 的浅色分组表单和蓝色主操作，授予反向访问和撤销使用红色并明确说明对象。沿用本次设计页面更新，旧稿由 Git 历史保存。

代码使用系统字体；Figma 使用既有 Noto Sans SC，避免已观察到的 SF Pro 渲染空白。所有文字显式设定可用宽度，并校验边界。此次为可编辑画板和部分导航演示，不交付独立组件库，也不是原生可输入界面。

## 界面与需求映射

| 界面 | Figma | 覆盖需求 | 截图 |
| --- | --- | --- | --- |
| 01 我的设备 | [61:3](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-3) | D1–D8，仅本机 | [PNG](evidence/01-my-devices.png) |
| 02 新 Mac 设置免密 | [61:4](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-4) | C、F，当前服务器数据 | [PNG](evidence/02-new-mac.png) |
| 03 双向免密确认 | [61:5](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-5) | R，本机凭据只读引用、别名可覆盖 | [PNG](evidence/03-confirm.png) |
| 04 双向验证结果 | [61:6](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-6) | 服务器详情已就绪状态 | [PNG](evidence/04-success.png) |
| 05 反向失败与恢复 | [61:7](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-7) | 服务器关系的部分完成 | [PNG](evidence/05-partial-failure.png) |
| 06 撤销反向授权 | [61:8](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-8) | 当前关系的撤销范围 | [PNG](evidence/06-revoke.png) |
| 07 编辑已保存凭据 | [61:9](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=61-9) | C，原密码保留和同步 | [PNG](evidence/07-credentials.png) |
| 08 连接方式：公网 | [67:2](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=67-2) | N，可选公网地址与外部端口 | [PNG](evidence/08-public-address.png) |
| 09 Tailscale 待接入 | [67:3](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=67-3) | N，官方登录与状态刷新 | [PNG](evidence/09-tailscale-login.png) |
| 10 服务器详情 | [67:4](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=67-4) | R，唯一双向操作所属位置 | [PNG](evidence/10-server-detail.png) |
| 11 Tailscale 地址就绪 | [67:5](https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY?node-id=67-5) | N，地址获取不等于 SSH 成功 | [PNG](evidence/11-tailscale-ready.png) |

## 交互契约

- 我的设备 → 配置连接方式 → 选择公网/Tailscale/局域网。公网展示地址与外部端口；Tailscale 展示客户端状态与接入入口；局域网实现为接口选择/手填表单，字段与限制见需求 N。
- Tailscale 未安装时提供安装入口，未登录时打开官方流程；用户返回后读取真实状态和本机地址。未安装、审批中、断开等文案变体见 requirements.md，不把演示跳转当成客户端已登录。
- 我的设备 → 编辑登录凭据。已有密码不重复输入；新密码留空保持原值，更换账户须重新绑定凭据。初次未保存状态沿用此入口，显示密码输入及保存选项，不另建第二份账户字段。
- 服务器详情 → 正向免密成功 → 红色开启双向免密 → 引用本机已保存账户与默认连接方式 → 可编辑本次别名 → 确认 → 分方向执行 → 成功或部分失败。
- 双向确认取消返回当前服务器详情，不能返回我的设备。修改本机配置的链接可暂时进入我的设备，返回后重新核对引用值，不隐式改写已授权关系。
- 服务器关系失败时支持修改地址并重试或精确撤销。“核对公钥”与“测试连接”分开；成功页和撤销页均属于当前服务器的关系流程。
- 切换服务器时来源名称、账户、地址、双向状态均重新读取；空列表不出现示例服务器卡片，异步旧请求不能污染新选中对象。
- 红色确认默认不获得键盘焦点；Escape 取消。运行中禁用重复提交并显示步骤。字段错误贴近输入，不以颜色作为唯一提示。

## 视觉与交互验收边界

画板宽 680，完整内容最高约 904。原生实现必须使用可滚动区域，支持 640 高窗口、大字体、长名称和长地址。Figma 静态画板中的字段不是实际输入控件。

导航只覆盖部分演示路径；“已登录，获取本机地址”到地址就绪、双向确认到成功页都是模拟，不连接网络、不保存凭据。安装、官方登录、局域网选择、实际保存和撤销结果须在实现时接通，不能把导航截图当作端到端验收。

## 本轮检查记录

十一张画板逐张截图检查，验证账号/地址可见、默认别名可辨、凭据单一入口、我的设备无服务器关系，服务器详情有双向操作。文本几何检查无零宽或父容器越界；原型导航无已删除节点引用。实际 SSH、Tailscale 客户端调用、iCloud、macOS 交互和认证测试均未执行。
