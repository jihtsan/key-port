# Issue #103 — 普通终端 SSH 别名

本阶段实现、真实短命令、原生交互及用户视觉验收通过。只剩前置堆叠链的验收与逐层合并门槛；本 PR 不接管 main，不关闭前置 Issue，也不展开 #100。

## 基线与实现

- 基于远端 PR #102 / `codex/issue-101-known-hosts-path` 的 `df00a5d603b010e3aa4d90200fec942ecdbe57e7`，创建独立分支 `codex/issue-103-short-ssh-alias`。
- 实现提交：`42f4473ca1f3df1d599579fd7f6982300ddbede7`；后续文档提交不改变 App。
- `SSHConfigService.AliasInstallation` 负责有独立所有权的配置接入；复用 `SSHConfigEntry`、`ServerConnection` 和 `SSHConfigGenerator`。旧工作区服务及其 `~/.ssh/keyport/config` 保持原有所有权。
- 新稳定文件为 `~/.ssh/keyport-access/config`。用户配置顶部只有有界 Include 块；托管文件和 Include 结束都恢复 `Host *` 作用域，原用户文件字节作为后缀保持不变。清空管理条目时移除块及托管配置。
- 身份文件、known_hosts 仍在稳定的 AccessPilot 根目录。配置不引用 worktree、dist 或 App executable；退出 App 后由本机 OpenSSH 独立工作。
- 只导出已验证默认路径。新增账户/地址不生成额外密钥；此次真实复验复用现有密钥，未输入密码。

## 默认路径与指定路径

1. 现有记录首次加载时以该服务器第一条保存路径建立默认映射；新服务器第一条保存路径成为默认，验证通过后才能导出。
2. `ssh <别名>` 固定到这条默认路径的账户、地址、端口和密钥；不是自动故障转移。新增地址不会替换默认路径。
3. 用户选择其他路径后，可通过“SSH 连接 → 设为默认连接”显式更新短别名目标；需要该路径已经验证。
4. Graph/列表明确选择非默认路径时，复制/终端使用 `ssh -F <稳定的该路径配置> <别名>`，确保不连接另一地址。详情明确标注默认或指定路径。
5. 修改 SSH 别名同步该服务器的路径，清除旧 Host；重复保存保持连接 ID 和默认映射，重新验证后导出。地址修改沿用前置设计成为新路径，经验证后可设为默认并删除旧路径。
6. 删除当前路径清理相应管理配置；删除默认路径不会偷偷选择另一地址。其他路径、账户授权和本机密钥保留。旧路径派生文件移入本地 retired 备份目录。

## 冲突与恢复

- 递归检查用户 Include、相对路径、带引号/空格路径及 glob；字面 Host、大小写、`*`/`?`、否定模式和多模式 Host 都参与冲突判断。
- 匹配新别名的通配规则阻止安装，不自动覆盖其优先级。Match 条件、全局选项、动态 Include、循环 Include、损坏/移位的管理块均明确报错；不运行 Match exec 来猜测结果。需用户解决具体冲突后重试。
- 认证前预检，写入时再次验证；对现有 managed 内容使用 receipt 校验，外部编辑不会被吞掉。用户删掉托管文件时，可以根据已保存事实重新生成。
- 配置写入有进程锁、原子替换、原权限保留，以及现存文件 ACL/扩展属性复制。备份成功后才能创建事务记录和改文件；临时文件以私有权限创建并同步落盘。
- 本地 `backup-*.json` 包含变更前后字节；`transaction.json` 是恢复日志。普通失败自动恢复，未结束事务在下次操作恢复；发现第三方同时修改时保留现场并报错，不覆盖第三方数据。测试覆盖三个写入位置失败和后续实例恢复。
- AccessPilot 非敏感状态修改前留独立备份。启动/同步根据保存状态重建派生配置；与配置导出相关的普通提交失败保留旧状态。
- 不改变 StrictHostKeyChecking，不自动接受指纹。真实复验只更新同一主机记录的 `lastSeenAt`，主机身份材料与本机密钥保持不变。

## 验收结果

| 条目 | 证据与边界 |
| --- | --- |
| 独立目录配置测试 | 10 项 AliasInstallation 测试：Include/顺序/空格、既有规则/大小写/通配/否定、原文件与权限保留、幂等、重命名、文件删除重建、逐写入失败、恢复、外部修改、符号链接和重复别名 |
| 工作区生命周期 | 13 项 AccessPilot 测试：首次接入/原安全回归、默认切换、指定路径、重命名、删除、重启、重复保存及冲突回滚；多路径验证使用独立测试数据，不声称真实第二个地址已连通 |
| 既有服务/界面 | 3 项 SSHConfigService 与 38 项 Interface 测试通过；最终全量结果见 evidence/test-summary.txt |
| 普通终端解析 | 实际执行 `/usr/bin/ssh -G tencent-cloud`，无需 -F；账户、地址、22 端口、唯一 IdentityFile 及 UserKnownHostsFile 与保存记录一致，密码/交互认证禁用，严格主机检查开启 |
| 真实 SSH | BatchMode + PasswordAuthentication=no + KbdInteractiveAuthentication=no，通过别名执行只读标记和 `id -un`，exit 0，返回 `ubuntu` |
| 无关连接保护 | 5 个已有别名的完整 `ssh -G` 输出逐字一致，旧 KeyPort 管理配置字节一致；本机钥匙记录未改动 |
| 原生成功页 | 当前 worktree App 使用既有密钥走完真实验证；成功页显示 `ssh tencent-cloud`，复制反馈为“已复制” |
| 列表与 Graph | 同一服务器、账户、端点、检测时间和默认短命令；已实际查看两种原生窗口与 AX，无重做布局 |
| 复制 | 原生菜单复制后实读剪贴板为 `ssh tencent-cloud`；成功页复制另行操作验证 |
| 终端交接 | App 实际启动 `ssh tencent-cloud`。Computer Use 不允许读取 Terminal，因此会话窗口由用户确认；用户回复“已进入远端命令提示符” |
| 退出 App | 等待精确 App 进程消失后执行短命令，返回 `KEYPORT_103_APP_EXIT_OK` 和 `ubuntu`，exit 0；第一次检查早于进程退出，不计为通过 |
| 重启 App | 从本 worktree 同一 App 路径重新启动，读取保存连接，短命令返回 `KEYPORT_103_RESTART_OK` 和 `ubuntu`，exit 0 |
| 签名与运行 | `./script/build_and_run.sh --access-pilot`；ad-hoc 签名 `codesign --verify --deep --strict` 通过，精确进程路径指向当前 worktree。不是 Production/公证验收 |
| 用户视觉验收 | 2026-09-14 用户回复“通过本阶段视觉验收”，覆盖新增 SSH 菜单、默认路径说明和短命令，不扩大为全部前置 Figma/CloudKit 验收 |

## 本地证据与合并边界

App：`/Users/joo00der/.codex/worktrees/b8bf/key-port/dist/KeyPortAccessPilot.app`。

已验证 App executable SHA-256：`128f1aa8e5ea71b093f6560c097ef84247f57df17eadb0549b1fca85ed646873`。

原生截图、AX、App 退出/重启证据、完整测试日志和本机 manifest 位于本任务本地 `issue103` 证据目录；服务器个人配置和截图不提交公共仓库。必要配置的首次备份在 `~/Library/Application Support/KeyPort/Issue103-backups/20260914-154209`，没有备份或读取私钥内容。

本 PR base 是 #102 分支。#91 → #93 → #95 → #97 → #99 → #102 仍有前置验收及逐层合并约束，不能把本次通过视为整条链可合入 main。PR 保持堆叠 Draft、Issue 保持 open；本阶段没有已知未完成的功能/本机验收项，剩余仅合并门槛。后续顺序保持 #100 → 真实全流程/Figma 收尾 → iCloud/迁移/旧代码清理与逐层合并，不在本 PR 展开。


## 用户要求后的再次验收（2026-09-14）

- 当前工作树干净，App executable SHA-256 仍与上述已验收版本相同；精确进程来自当前 worktree，签名校验通过。
- 再次执行普通 `ssh -G tencent-cloud`，账户、地址、端口、密钥与保存记录一致；5 个原有别名解析不变。
- 再次以 BatchMode 并禁用密码/交互认证登录，返回 `ACCEPTANCE_RECHECK_OK` 与 `ubuntu`，exit 0。
- 原生 App 点击“测试路径”，反馈“当前路径已通过主机身份与免密登录验证”。
- 本轮 62 项定向测试通过，无失败、无跳过：AccessPilot 13、AliasInstallation 10、SSHKnownHostsPath 1、Interface 38。此前标准全量套件跳过的信任路径实机测试，本次通过显式指定已授权端点和既有 known_hosts 完成；未接受新指纹或发送密码。
- 本轮仅补充验收记录，不修改实现；#104 仍基于 #102，前置链合并条件没有因重复验收而自动解除。
