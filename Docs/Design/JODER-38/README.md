# KeyPort macOS 菜单栏 Icon 方案

本目录包含 JODER-38 的三套可评审方向。图形均为 18 x 18 pt、单色、透明背景的 SVG，按 macOS template image 思路设计：运行时由系统着色，不在源文件中编码品牌色，也不依赖颜色表达状态。

## 已选定生产方向

用户选定 GPT Image 生成的 `keyport-app-icon-source.png` 作为 App Icon。图形以三节点可信拓扑围绕中央钥匙，保留了「设备互联」「SSH 密钥」和「集中管理」三层语义。源图为 1254 x 1254 RGBA PNG；`render-production-assets.sh` 从同一源图生成标准 macOS `.icns`，避免各尺寸构图漂移。

`keyport-menu-template.svg` 是根据用户提供的黑白稿重新绘制的 18 x 18 pt 生产候选：保持三节点与中央钥匙的构图，统一为 1.5 pt 圆角线条，并扩大内部留白以保证菜单栏尺寸可辨。它导出为 18 px / 36 px 透明 template PNG，由系统负责浅色、深色和高亮状态着色。

## 推荐：A · Key Hub / 密钥中心

`key-hub.svg` 以钥匙圆环作为中心节点，左右两端是设备节点，向下延伸的钥匙齿表达 SSH 凭据。它同时覆盖「SSH 密钥」「设备互联」「中心化管理」三层语义，且在 18 pt 下轮廓最稳定。中文定位使用「密钥中心」时，图形和名称也能直接互相解释。

- 核心隐喻：密钥圆环即可信连接的中心。
- 构图：横向节点保证菜单栏轮廓清楚，垂直钥匙齿形成视觉锚点。
- 适用：默认菜单栏图标、连接正常的中性状态。
- 取舍：中心化语义最强；设备形态使用抽象节点而非具体电脑，跨设备类型更通用。

## B · Trust Link / 可信链路

`trust-link.svg` 以两台设备和中间的双向链路表达同一账户内的设备互联，方向箭头也对应连接建立与授权回路。

- 核心隐喻：两端设备通过受信任链路互通。
- 构图：对称设备框稳定，中间双向箭头是动作焦点。
- 适用：强调设备互联、同步或连接状态的入口。
- 取舍：互联语义最直接，但钥匙语义较弱，脱离 KeyPort 名称时可能被理解为通用同步工具。

## C · Key Route / 密钥路由

`key-route.svg` 将一把对角钥匙连接到两个端点，表达同一密钥管理入口把授权路由到多台设备。

- 核心隐喻：SSH 密钥沿可信路径到达设备。
- 构图：钥匙圆环在左上、钥匙齿在右下，第二节点形成分支关系。
- 适用：强调授权分发或设备扩展的功能入口。
- 取舍：动态感最强且不似通用锁具；非对称轮廓在极小尺寸下比 A 更活跃，也稍少 macOS 状态栏的静态感。

## 文件与验证

- `keyport-app-icon-source.png`：用户选定的 App Icon 原始生成图。
- `keyport-menu-template.svg`：按 18 pt 网格优化的菜单栏矢量源文件。
- `keyport-production-icon-review.png`：选定 App Icon 与浅/深菜单栏实际尺寸预览。
- `Resources/KeyPort.icns`：应用包使用的完整 macOS 图标资源。
- `Resources/KeyPortMenuTemplate.png`、`KeyPortMenuTemplate@2x.png`：18 px / 36 px 菜单栏 template image。
- `key-hub.svg`、`trust-link.svg`、`key-route.svg`：18 x 18 pt 矢量源文件。
- `exports/*@1x.png`：18 x 18 px 实际 1x 栅格。
- `exports/*@2x.png`：36 x 36 px Retina 2x 栅格。
- `keyport-menubar-icon-review.png`：放大构图、浅/深菜单栏与 1x/2x 实际尺寸联系表。

本地重新导出：

```bash
./Docs/Design/JODER-38/render-production-assets.sh
./Docs/Design/JODER-38/render.sh
```

验证项目：SVG 均为 18 x 18 viewBox、仅使用黑色与透明度；PNG 导出应分别为 18 x 18 和 36 x 36，颜色类型应含 alpha。联系表中的实际尺寸图标保持原始像素，不做平滑放大。

## 应用接入

`script/build_and_run.sh` 将 `KeyPort.icns` 拷贝到应用包，并通过 `CFBundleIconFile` 注册 App Icon；同时将菜单栏 1x/2x PNG 拷入应用资源目录，为后续 `NSStatusItem` / `MenuBarExtra` 接入保留生产资源。菜单栏代码接入时应设置 template rendering，不在图标内部加入状态色；错误、离线或需操作状态应另用菜单文案、badge 或独立状态变体表达。

尚未解决的风险：当前应用尚未实现 `NSStatusItem` / `MenuBarExtra`，因此菜单栏资源已经打包但还没有运行时消费者；正式接入时仍需在最低支持版本 macOS 14 的真实菜单栏中检查常态、高亮态和不同显示缩放。
