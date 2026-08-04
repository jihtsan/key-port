# SSH KeyPort 一期 SSH 技术原型结论

- 日期：2026-08-04
- 原型范围：Host Key、密钥扫描与生成、密码认证桥接、公钥认证、`authorized_keys` 安全更新、SSH Config
- 当前实现：系统 OpenSSH 受控适配层

## 结论

一期暂不引入 Citadel。当前机器没有可用于真实服务器互操作测试的 Linux SSH 端点，也没有完整 Xcode；在无法验证 Citadel 的 Host Key 回调、OpenSSH 私钥格式、RSA 兼容和 SFTP 原子替换行为时，把第三方 SSH 栈直接放进安全核心不满足需求文档的准入门槛。

当前实现使用系统 OpenSSH 10.2，并将能力限制在固定内部操作：

- `ssh-keyscan` 只获取当前网络端点返回的 Host Key，不将其描述为可信验证结果。
- 使用 SHA256 公钥指纹比较确认记录；未知或变化的 Host Key 在认证前阻断。
- Ed25519 由系统 `ssh-keygen` 生成；扫描同时识别 Ed25519 和 RSA OpenSSH 公钥。
- 密码不进入参数、环境值、数据库、CloudKit、日志或普通 stdin。主应用在 LocalAuthentication 成功后从 Keychain 读取密码，并通过权限为 `0600` 的随机一次性 FIFO 交给 `SSH_ASKPASS` helper；helper 不具备 Keychain 查询能力。
- 密钥认证使用 `BatchMode`、专用 `known_hosts` 和显式私钥，成功后执行固定 `exit` 并立即断开，不申请 PTY 或交互式 Shell。
- 公钥注入只运行内置的固定 `sh -s` 脚本。脚本按公钥 blob 去重，保留未知行和选项，创建权限受控备份，通过同目录临时文件原子替换，并在替换后验证。
- 撤销只删除公钥 blob 完全匹配的行；不根据备注删除，也不修改未知公钥。

## 已验证

- 本机 OpenSSH 10.2 可生成 Ed25519 密钥并输出 OpenSSH SHA256 指纹。
- Swift 核心解析器覆盖带 `from=`、`command=` 等前置选项的 `authorized_keys` 行。
- Host Key 状态机对同算法指纹变化返回阻断状态。
- SSH Config Include 插入在任何 `Host` 段之前，且重复执行幂等。
- 应用和 AskPass helper 可由 SwiftPM 构建并装入标准 `.app` bundle。

## 真实环境验证缺口

发布前必须在隔离的 Linux/OpenSSH 测试矩阵补齐：

1. Ed25519/RSA 用户密钥、Ed25519/RSA/ECDSA Host Key 与不同 OpenSSH 版本。
2. 密码、keyboard-interactive、禁用密码、只允许 SFTP、自定义 shell 和断网/取消场景。
3. 使用 `ps`、统一日志和崩溃报告确认密码从未泄漏。
4. 注入与撤销期间的进程终止、磁盘满、权限异常和远端并发修改。
5. 最终 `ssh <alias>` 的真实登录验证。

若该矩阵暴露系统 OpenSSH AskPass 生命周期或远端 shell 兼容性不可接受，再用相同服务协议替换为 Citadel 或审计后的 libssh2 封装；不能通过降低 Host Key 校验或把密码移入参数来规避问题。
