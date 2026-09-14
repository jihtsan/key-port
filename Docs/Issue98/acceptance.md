# Issue #98：真实 OpenSSH 接入验收

## 当前结论

已实现独立的真实连接入口，等待用户在原生表单填写服务器后进行真实 SSH 验收。PR 保持 Draft；本阶段不合并或替换 main。

基线为 #96 / PR #97 的 4e318d1。由同一 KeyPort executable 注入 KeyPortInterface 与 OpenSSHFirstAccessAdapter；独立 bundle identifier 决定使用验收入口，正式 App 继续原入口。设计预览仍使用 fixture adapter。

## 实施范围

- 单表单 → ED25519 主机指纹确认 → 密码或指定本机私钥登录 → 核对授权 → 必要时幂等安装 → BatchMode 公钥复验 → 终端交接。
- 复用 OpenSSHService、SSHKeyService、公钥解析、远端闭集脚本与 AskPass FIFO。真实入口通过 ProcessRunner 注入现有 ProcessExecutor：10 秒总执行时间、512 KiB 合并输出上限、取消后 TERM / 2 秒后 KILL。修正 ProcessExecutor 正常结束时取消超时任务仍触发超时的竞态。
- 全部实际 SSH 请求忽略系统与用户配置，强制已确认 known_hosts、禁用连接复用及代理转发。只执行本机 OpenSSH，不接管 SSH 会话。
- 密码只在本次内存和受保护 FIFO 中使用，不进入参数、环境值、JSON 或终端脚本。界面密码提交、取消、失败时清空。
- 授权记录包含本机设备、节点、账户、密钥身份；新增地址仍需确认该端点身份，必须与所选节点既有身份匹配。先试公钥，拒绝时使用已验证密码读取 authorized_keys；已有精确公钥不重复安装。写入前保存 unknown，取消不声称回滚。
- 保存非敏感连接与检测时间；列表/Graph/详情来自相同 snapshot。新地址增为独立路径。路径测试不会安装公钥。
- 每条路径写独立 OpenSSH config；成功页复制/终端交接使用 `ssh -F <该路径配置> <别名>`，避免多地址同别名时打开错误路径。
- 工作区读取失败显式报错，不用空白状态覆盖。进程文件锁阻止两个验收窗口同时写同一工作区。

## 运行与数据边界

运行 `./script/build_and_run.sh --access-pilot`；构建脚本 `script/build_access_pilot.sh` 仅打包并校验签名。

App：`dist/KeyPortAccessPilot.app`；bundle ID：`com.jihtsan.KeyPort.AccessPilot`。

本地验收根目录：`~/Library/Application Support/KeyPort/AccessPilot`。其内部使用现有 KeyPortPaths 布局存放身份、known_hosts、各路径配置与验收状态。不会修改用户 `~/.ssh/config`，不会导入正式工作区或启用 CloudKit。使用显式 `-F` 的独立命名空间；正式全局别名接管与迁移仍属于后续阶段。

密码模式首次生成该入口的本机专用 ED25519 密钥。现有密钥模式可填写私钥绝对路径，要求同名 `.pub` 存在；私钥由 OpenSSH 读取，不复制到数据库。留空优先使用已保存账户密钥，然后使用该入口已生成的密钥。当前不接入 agent 或交互式私钥口令解锁；受保护私钥需要后续专门交互。主机侧本阶段要求提供 ED25519 host key。

## 已验证与证据

- 全量 `./script/test.sh`：KeyPort 201、KeyPortInterface 37、KeyPortCore 312、TunnelBroker 1 项通过，CoreChecks、SSHRelay fixtures、AskPass FIFO 检查通过。此轮包含最初 8 项新测试。
- 后续增加重试别名归属与本机 `ssh -G` 配置解析测试；最终定向覆盖 10 项 AccessPilot、10 项 ProcessExecutor 与 37 项 Interface 测试。末次适配器/关闭回写修正后再次运行 10 项 AccessPilot 测试。
- 新测试覆盖：密码首次授权/持久化、错误密码、已存在远端公钥、同节点新增地址、指纹变更阻断、失败重试别名、独占锁/损坏文件、配置注入保护、本机 OpenSSH 配置解析、取消/超时映射。
- 适配器测试注入受控 ProcessExecuting 结果，不冒充真实远端 SSH；ProcessExecutor、AskPass 与 SSHRelay 检查执行真实本机进程。
- 原生 App 已启动，查看空白首页与 SSH 表单。截图、构建/测试记录见 evidence 目录；不包含用户凭据。

## 用户填写后的验收顺序

1. 在 App 填别名、可选中文描述、地址、端口、账户和密码；由用户通过可信渠道核对完整指纹并确认。
2. 检查实际密码登录、公钥安装与免密复验；成功页和列表/Graph 状态、地址、账户及检测时间一致。
3. 检查错误凭据/不可达/取消后的恢复；不得将失败、未知或旧记录显示为本次成功。
4. 重试同账户、增加同服务器另一地址，核对 authorized_keys 不重复增加同一公钥；不同主机身份必须阻断。
5. 重启 App 恢复连接与描述；复制命令用 `ssh -F` 命中正确路径；终端交接以用户可见会话确认。
6. 记录真实证据与用户验收结论后再决定 PR 合并。CloudKit、生产签名、跳板机、正式全局 SSH Config 接管和旧数据迁移均未验收。
