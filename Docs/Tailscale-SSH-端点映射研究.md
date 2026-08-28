# Tailscale 节点与 SSH 端点映射研究

- 日期：2026-08-12
- 范围：Tailscale 节点、OpenSSH `Host`/`HostName`、内网/公网地址之间的可证明关联
- 来源：仅 Tailscale、OpenSSH 官方文档与 Tailscale 官方源码

## 结论

Tailscale 没有提供“导出每个节点对应的 OpenSSH `Host`/`HostName`、LAN IP、公网 SSH IP”的官方直接接口。可靠实现应把数据分成三类：

1. **确定性关联**：同一 tailnet 内，以 Devices API 的 `nodeId` 为节点主键；只把该节点的 `addresses`（Tailscale IP）和 `name`（MagicDNS FQDN）作为它的 Tailscale 地址。`tailscale status --json` 的 `PeerStatus.ID`、`DNSName`、`TailscaleIPs` 表达相同类型的信息，但官方 CLI 明示 JSON 格式可能变化，不宜作为永久存储协议。[Devices API schema](https://api.tailscale.com/api/v2) [CLI `status`](https://tailscale.com/docs/reference/tailscale-cli#status) [PeerStatus source](https://github.com/tailscale/tailscale/blob/d200b3f18f0ee4cff1f6819a78a9fe8e6a7367f2/ipn/ipnstate/ipnstate.go#L234-L268)
2. **用户确认的关联**：LAN/private IP、普通 DNS 名、公网 IP 或另一个 SSH alias 只有在用户明确确认、已有持久映射，或有独立的机器稳定 ID/云实例 ID 时，才能绑定到 `nodeId`。
3. **发现提示，不自动合并**：相同显示名、OS hostname、同一公网出口、Tailscale transport endpoint、SSH Host Key 或“当前可达”只能提示候选，不能单独证明机器同一性。

## 标识与证据强度

| 字段/证据 | 可用于 | 强度与限制 |
| --- | --- | --- |
| Devices API `nodeId` | Tailscale 设备主键 | 最强；官方称为设备唯一且首选的 API 标识。设备被删除后重新加入是否保持相同 `nodeId`，官方所引资料未承诺，不能假定。 |
| `addresses` / `TailscaleIPs` | 匹配 `HostName` 为 Tailscale IPv4/IPv6 | 强；Tailscale 文档称节点地址稳定，但管理员可改地址，设备重建也不应仅靠地址维持身份。[IP assignment](https://tailscale.com/docs/concepts/ip-and-dns-addresses) |
| `name` / `DNSName` | 匹配 MagicDNS FQDN | 强地址证据，但不是不可变身份；设备改名会同步改变 MagicDNS 名。[MagicDNS](https://tailscale.com/docs/features/magicdns) [Machine names](https://tailscale.com/docs/concepts/machine-names) |
| `hostname` / `HostName` | 候选展示、辅助确认 | 弱；Tailscale 源码明确说明 OS hostname 不一定唯一，设备名也可被用户或 OS 更新。 |
| API `clientConnectivity.endpoints`、status `Addrs`/`CurAddr` | 网络诊断 | 很弱；它们是 Tailscale magicsock 的 UDP `IP:port` 候选/当前直连端点，不是 SSH 地址或 SSH 端口。[Devices API schema](https://api.tailscale.com/api/v2) [PeerStatus source](https://github.com/tailscale/tailscale/blob/d200b3f18f0ee4cff1f6819a78a9fe8e6a7367f2/ipn/ipnstate/ipnstate.go#L261-L268) |
| `tailscale netcheck` 公网 IPv4/IPv6 | 本机网络诊断 | 不能绑定远端节点；`MappingVariesByDestIP` 还可能表明 NAT 映射随目标变化。[CLI `netcheck`](https://tailscale.com/docs/reference/tailscale-cli#netcheck) |
| SSH Host Key 指纹 | 用户确认后的端点连续性 | 可确认“这次 SSH 服务与已信任服务相同”，但同一机器可重装/轮换 key，多台别名也可指向同一服务；它不提供 Tailscale `nodeId`。 |

因此，共享 NAT/CGNAT 下多台设备可能拥有同一公网 IPv4；多宿主设备可能同时暴露多个 LAN/公网地址；公网 IP 和 NAT 端口可能动态变化；多个 SSH alias 也可能解析到同一 `HostName`。这些情形都排除“按公网 IP 或别名自动一对一合并”。DERP 的 `Relay` 只表示中继区域，也不是节点公网地址。

## 三种部署拓扑

| 拓扑 | 本机 Tailscale 能证明什么 | 映射策略 |
| --- | --- | --- |
| Tailscale 安装在 SSH 目标机 | `nodeId`、MagicDNS、Tailscale IP 属于目标节点 | `HostName` 精确等于 MagicDNS/Tailscale IP 时可自动关联；LAN/公网地址仍需额外证据。 |
| Tailscale 只安装在跳板机/子网路由器 | 只能证明跳板/路由节点身份；后端 private IP 是其路由前缀中的地址，不是该 Tailscale 节点自身 | 将跳板和最终 SSH 目标建模为不同实体；不能把后端 `HostName 10.x/192.168.x` 合并到跳板 `nodeId`。 |
| 仅有 SSH config，目标和跳板均无本机可见 Tailscale 身份 | Tailscale 数据不能证明 alias 对应节点 | 解析 OpenSSH 有效配置并要求用户确认；保持未关联是正确结果。 |

Tailscale SSH 与“通过 Tailscale 网络运行普通 OpenSSH”也应区分。Tailscale SSH 在启用节点的 Tailscale IP:22 上接管流量并分发其 SSH host key；普通 OpenSSH 仍可通过 Tailscale IP/MagicDNS 工作。[Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)

## OpenSSH 配置的正确读取方式

`Host` 是用户输入名称的匹配模式，不是机器身份；`HostName` 是最终要连接的真实主机名/地址。配置按命令行、用户文件、系统文件读取，而且通常“首个取值生效”，并支持 `Include`、通配符、`Match` 与 canonicalization。因此不能仅扫描文本块建立真实目标映射，应对每个候选 alias 使用：

```bash
ssh -G <alias>
```

`ssh -G` 会在计算 `Host`/`Match` 后输出有效配置；至少读取 `hostname`、`port`、`user`、`proxyjump`、`proxycommand` 和 `hostkeyalias`。[ssh(1) `-G`](https://man.openbsd.org/ssh#G) [ssh_config(5)](https://man.openbsd.org/ssh_config)

`ProxyJump` 先连接跳板，再从跳板转发到最终 `HostName`；`ProxyCommand` 可以执行任意能建立字节流的命令。最终目标、跳板和代理进程可能是三个不同实体，不能因一条 SSH 配置而继承同一 Tailscale 身份。[ProxyJump](https://man.openbsd.org/ssh_config#ProxyJump) [ProxyCommand](https://man.openbsd.org/ssh_config#ProxyCommand)

## 建议的数据规则

- 持久化 `tailnet + nodeId` 为 Tailscale 身份；MagicDNS、Tailscale IP、显示名和 endpoints 都是可刷新属性。
- 自动匹配仅接受标准化后的 MagicDNS FQDN 或 Tailscale IP 精确相等；若多个节点命中、节点已重建或身份冲突，停止自动关联。
- LAN/private IP、普通 DNS、公网 IP、额外 alias 记录为用户确认的 endpoint link，保留证据类型、确认时间和最后验证时间。
- 公网 endpoint 仅用于展示/诊断，不从 UDP endpoint 推导公网 SSH `HostName:Port`，不因共享出口相同而合并。
- 每个 SSH alias 独立保存有效配置；`ProxyJump`/`ProxyCommand` 建立显式的“经由”关系，不折叠目标与跳板。
- Host Key 继续作为 SSH 服务信任边界；即使 Tailscale 节点匹配，也不能替代现有 Host Key 确认。

## 可实施的匹配流程

1. 从 Devices API 读取 tailnet 内节点，以 `tailnet + nodeId` 建立清单，并定期刷新 MagicDNS、Tailscale IP、节点名、OS、tags 与最后可见时间。无 API 权限时，可使用本地 `tailscale status --json` 做临时发现，但需记录 CLI 版本并容忍未知字段。
2. 对 SSH config 中每个无通配符 alias 执行 `ssh -G -- <alias>`，读取有效 `hostname`/`port`/`user` 及路由字段。不执行 SSH 连接、DNS 探测或端口扫描。
3. 若最终 `hostname` 与某节点 MagicDNS 或 Tailscale IP 标准化后唯一精确相等，则自动关联；将 `ProxyJump`/`ProxyCommand` 另存为路由，不继承跳板机身份。
4. 若只有 LAN IP、公网 IP、普通 DNS、相似主机名或共享出口，则保持未匹配，可向用户展示候选证据，但必须由用户确认或加入独立的机器/云实例稳定 ID。
5. 任何多节点命中、已持久映射与当前数据冲突、节点重建或 Host Key 变化，都停止自动合并并标记待复核；不用“多数决”覆盖原映射。

### 最小人工映射记录

| 字段 | 用途 |
| --- | --- |
| `tailnet`, `nodeId` | 唯一的 Tailscale 节点引用 |
| `serverId` | KeyPort 中的机器/服务器主键，不用可变的显示名作为外键 |
| `sshAlias`, `resolvedHost`, `port`, `user` | 保留 SSH 账户边界；多 alias/多用户可共用一个 `serverId` |
| `route` | 直连、`ProxyJump` 或 `ProxyCommand`；跳板机另存身份 |
| `evidenceType`, `evidenceValue` | `exact_magicdns`、`exact_tailnet_ip`、`stable_machine_id` 或 `user_confirmed`；值应最小化并不含凭据 |
| `confirmedAt`, `lastVerifiedAt`, `verifiedBy` | 审计、刷新与过期判断 |

维护时以 `nodeId`/`serverId` 为主键，把 IP、DNS 与 alias 当作可变属性。建议在节点消失、`nodeId` 改变、SSH 有效配置改变、Host Key 变化或映射长期未验证时进入人工复核，不覆盖历史证据。

## 安全的只读验证

```bash
# 只读取本机已可见的 Tailscale 状态；输出可含内部地址，不应直接贴入 Issue/日志
tailscale version
tailscale status --json

# 只解析本地 OpenSSH 有效配置，不建立网络连接
ssh -G -- <alias>
```

Devices API 调用必须使用最小只读权限，Token 放入密钥存储或受控环境变量，不放在命令行、应用日志、Issue 或映射表。对生产 SSH、云 API、DNS 或防火墙的读取也需另行授权；本研究未进行这些操作。

## 官方直接导出能力

截至本研究日期，官方能力是组合式而非一键导出：Devices API 提供节点、Tailscale 地址、MagicDNS 名和可选网络连接诊断；`tailscale status --json` 提供本地可见 peer 状态；`tailscale netcheck` 提供执行节点自身的公网/NAT 诊断；OpenSSH `ssh -G` 提供 alias 的有效配置。没有官方字段或命令声明某个 Tailscale `nodeId` 对应哪些 LAN IP、公网 SSH IP 或任意 OpenSSH aliases。

**未验证假设：**“没有直接导出”是基于上述当前官方 API schema、CLI 文档和官方 CLI 源码的检索结论，不是 Tailscale 对未来产品能力的保证；实现仍应对未知字段保持前向兼容，并在升级 Tailscale 后复核。
