# SSH KeyPort

KeyPort 是一款 macOS 原生 SSH 免密授权管理工具。它把服务器端点、SSH 账户、本机设备、密钥和授权关系整理在一个界面中，帮助用户安全完成 Host Key 确认、公钥授权、SSH Config 生成和多台 Mac 的独立授权。

KeyPort 不提供内置终端、交互式 SSH 会话或远程命令工作台。完成配置后，Terminal、脚本或其他外部工具通过稳定的 SSH 别名连接服务器：

```bash
ssh <ssh-alias>
```

## 当前状态

- 项目阶段：一期 MVP，当前以源码构建为主。
- 支持平台：macOS 14 或更高版本。
- 工具链：Swift 6；当前仓库验证环境使用 Swift 6.3.3 和 Apple Command Line Tools。
- 当前验证：核心回归检查、AskPass FIFO 集成检查和 SwiftPM 构建通过。
- 发布状态：仓库暂未提供签名、公证的正式发行包。

## 功能概览

| 能力 | 说明 |
| --- | --- |
| 服务器与 SSH 账户 | 添加、编辑、删除和搜索账户；同一端点上的多个账户会被分组展示，用户名、别名和授权状态仍按账户区分。 |
| Host Key 管理 | 扫描服务器主机密钥，要求用户明确确认；未确认或发生变更时阻止认证和授权。 |
| 本机密钥管理 | 扫描现有 SSH Config、公钥文件和 SSH Agent；支持导入 OpenSSH Ed25519/RSA 私钥和生成 Ed25519 密钥。 |
| 公钥授权 | 通过一次密码认证将本机公钥安装到远端 `authorized_keys`，安装后再用密钥认证验证。 |
| 授权读取与撤销 | 读取 KeyPort 管理的远端授权，按公钥指纹精确撤销指定设备密钥，并保留未知公钥和选项。 |
| SSH 别名与配置 | 生成 `~/.ssh/keyport/config`，并在用户配置中加入幂等的 Include；已有 SSH 配置不会被整体覆盖。 |
| 设备与 Tailscale | 记录当前 Mac 和其他设备的密钥授权；可读取 Tailscale 节点并为可用的 SSH 端点提供账户建议。 |
| Test Case 节点关联 | 使用上游稳定节点 ID，通过唯一 MagicDNS/Tailscale IP 强证据自动关联，或人工确认、改绑和解除；漂移时阻止关联驱动的执行。 |
| 同步与归档 | 通过 CloudKit 同步非敏感元数据；可选使用 iCloud Keychain 同步服务器密码；支持加密元数据归档。 |
| 审计日志 | 记录授权、密钥、SSH 配置、同步和归档等操作结果。 |

## 安全边界

KeyPort 将连接元数据、密码和私钥分开处理：

- 服务器密码只保存到 macOS Keychain。密码值不会进入 CloudKit、应用快照、命令参数或普通日志；同步密码需要带有正确团队签名和 Keychain entitlement 的构建。
- 每台 Mac 使用自己的私钥。私钥保存在本机 `~/.ssh/keyport/identities/`，不上传 CloudKit，也不放入元数据归档。
- SSH 认证使用 KeyPort 专用的 `known_hosts` 和严格 Host Key 校验。Host Key 未确认或不匹配时，操作会被阻止。
- 密码认证通过 LocalAuthentication 后由主应用从 Keychain 读取，再经权限为 `0600` 的一次性 FIFO 交给 `KeyPortAskPass` helper；密码不会作为命令行参数传递。
- 远端 `authorized_keys` 更新会按公钥内容查重，保留未知行和选项，写入前创建受限备份，使用同目录临时文件原子替换，并在操作后重新验证。
- SSH 操作限定为 Host Key 扫描、认证检查、机器信息读取和授权文件维护，不开启交互式 Shell 或 PTY。

## 环境要求

### 本地开发环境

- macOS 14+
- Swift 6 工具链，可通过 Xcode 或 Apple Command Line Tools 提供
- 系统 OpenSSH 工具：`ssh`、`ssh-keyscan`、`ssh-keygen` 和 `ssh-add`

### 远端 SSH 环境

一期实现面向常见的 OpenSSH 环境。用于授权的 SSH 账户需要能够修改自己的 `~/.ssh/authorized_keys`，远端也需要支持通过 `sh -s` 执行固定维护脚本。

### 可选能力

- Tailscale 设备发现：需要安装并登录 Tailscale 客户端。
- CloudKit 和 iCloud Keychain：需要 Apple Developer 团队配置、正确的 App ID/entitlement、签名构建以及相同 Apple ID 的 iCloud 环境。源码构建的 ad-hoc 签名不会启用 iCloud Keychain 同步。

## 快速开始

```bash
git clone https://github.com/jihtsan/key-port.git
cd key-port

# 编译 SwiftPM 产品
swift build

# 运行核心检查和 AskPass FIFO 集成检查
./script/test.sh

# 组装、签名并启动 KeyPort.app，同时验证应用进程已启动
./script/build_and_run.sh --verify
```

也可以直接启动应用：

```bash
./script/build_and_run.sh run
```

`script/build_and_run.sh` 支持以下模式：

```text
run          构建并启动应用
--verify     构建、启动并检查应用进程
--debug      使用 lldb 启动应用二进制
--logs       启动应用并查看进程日志
--telemetry  启动应用并查看 KeyPort subsystem 日志
```

脚本会在 `dist/KeyPort.app` 生成本地 ad-hoc 签名的应用包。正式发布所需的 Developer ID、iCloud entitlement 配置和公证不包含在本地构建脚本中。

## 首次使用

1. 在“服务器”中添加服务器端点和 SSH 用户，填写主机、端口、用户名和 SSH 别名。
2. 检查扫描到的 Host Key 指纹，确认服务器身份。不要在指纹异常时继续授权。
3. 在“密钥”中扫描已有身份、导入 OpenSSH 私钥，或为当前 Mac 生成 Ed25519 密钥。
4. 将服务器密码保存到 Keychain，并执行密码 SSH 检查。
5. 选择“授权此 Mac”或“保存并授权”。KeyPort 会安装本机公钥并验证免密 SSH。
6. 使用生成的别名连接：

   ```bash
   ssh <ssh-alias>
   ```

7. 在“设备”中查看各 Mac 的密钥，在服务器详情中刷新或撤销远端授权；在“审计日志”中检查操作结果。

服务器账号的别名是账号级入口。同一服务器端点存在多个用户名时，每个用户名都有独立的密码、密钥授权和 SSH 别名。

## 本地文件

KeyPort 使用以下路径保存 SSH 文件和非敏感应用状态：

| 路径 | 用途 |
| --- | --- |
| `~/.ssh/keyport/identities/` | 当前 Mac 的 KeyPort 私钥和公钥，目录权限为 `0700`。 |
| `~/.ssh/keyport/config` | KeyPort 生成的 `Host` 配置，文件权限为 `0600`。 |
| `~/.ssh/keyport/known_hosts` | 已确认的服务器 Host Key，文件权限为 `0600`。 |
| `~/.ssh/config` | 仅在需要时加入 `Include ~/.ssh/keyport/config`，不会替换用户原有内容。 |
| `~/Library/Application Support/KeyPort/state-v1.json` | 版本化的本地非敏感状态，目录和文件权限受控。 |

CloudKit 上传前会移除本地私钥路径、SSH Agent 状态、当前设备标记、检测状态和审计日志。加密 `.keyport` 归档包含服务器、别名、公钥、设备和授权元数据，但不包含服务器密码、私钥、本地路径或审计日志。

## 工程结构

这是一个 Swift Package，主要产品如下：

| Target | 用途 |
| --- | --- |
| `KeyPort` | SwiftUI/AppKit macOS 主应用。 |
| `KeyPortCore` | 领域模型、SSH Config、Host Key、公钥、Tailscale 和归档解析/生成逻辑。 |
| `KeyPortAskPass` | 通过受限 FIFO 为系统 OpenSSH 提供一次性密码输入的 helper。 |
| `KeyPortCoreChecks` | 不依赖 UI 的核心回归检查。 |
| `KeyPortCoreTests` | 节点关联、迁移、漂移、并发与敏感数据边界的 XCTest。 |

主要目录：

```text
Sources/
  KeyPort/        macOS 应用、视图、状态模型和系统服务
  KeyPortCore/    可测试的领域模型与解析器
  KeyPortAskPass/ OpenSSH AskPass helper
  KeyPortCoreChecks/
                  核心回归检查
Resources/        entitlements
Docs/             需求、架构、SSH 原型和技术选型文档
script/           构建、打包和测试脚本
```

应用状态由 Observation `AppModel` 持有，SSH、Keychain、CloudKit、文件和归档操作由独立 Actor 服务隔离。界面使用 SwiftUI，窗口和系统能力通过少量 AppKit 互操作完成。

## 验证命令

最小验证：

```bash
./script/test.sh
```

更完整的本地检查：

```bash
swift build -c release
git diff --check
./script/build_and_run.sh --verify
```

其中 `./script/test.sh` 会执行 `KeyPortCoreChecks`、构建 `KeyPortAskPass`，并通过受保护 FIFO 验证 helper 只消费一次密码输入。

## 已知限制

- 当前仓库没有签名、公证的发行包；正式使用 iCloud 能力需要配置真实开发者团队和 entitlement。
- 当前本地验证不覆盖隔离 Linux/OpenSSH 多版本矩阵、真实远端原子写入、CloudKit 冲突处理或两台 Mac 之间的 iCloud Keychain 同步。
- 远端授权范围限定为用户有权直接维护自己 `authorized_keys` 的常见 OpenSSH 场景。
- KeyPort 是 SSH 授权和入口管理工具，不是终端、命令执行器或基础设施监控产品。

## 相关文档

- [一期需求规格](Docs/SSH-KeyPort-一期需求规格.md)
- [一期实现架构与验证说明](Docs/一期实现架构与验证说明.md)
- [SSH 技术原型结论](Docs/SSH-技术原型结论.md)
- [macOS 技术框架与组件选型](Docs/macOS-技术框架与组件选型.md)
- [项目术语与上下文](CONTEXT.md)
- [界面与交互设计约束](DESIGN.md)
- [JODER-30 节点关联实现说明](Docs/JODER-30-节点关联实现说明.md)

## 贡献前检查

提交改动前，请至少运行：

```bash
./script/test.sh
swift build -c release
git diff --check
```

涉及 macOS UI、打包或安全流程的改动，还应运行 `./script/build_and_run.sh --verify`，并在具备真实远端环境时补充 SSH、Host Key 和授权撤销验证。
