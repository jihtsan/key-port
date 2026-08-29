# KeyPort

KeyPort 管理个人的网络访问拓扑：节点、节点的网络端点、逻辑服务、协议相关的访问凭据与授权，以及当前设备对这些事实的本地观测。

## 核心拓扑

**Workspace（工作区）**：
一个用户维护的 KeyPort 数据集合，包含节点、节点角色、工作区设备档案、访问端点、协议账户、密钥、服务、授权和本地观测。
_Avoid_: 账户、项目、集群

**Node（节点）**：
一个具有稳定身份的物理机、虚拟机、网络设备或其他可被访问的网络参与者。同一个节点可以同时承担客户端设备、SSH 主机、VPN 网关、RDP 主机或服务承载节点等多个角色。
_Avoid_: Host、Device、IP、SSH 账户

**Node Role（节点角色）**：
节点在某个访问或承载场景中的能力，例如客户端设备、SSH 主机、VPN 网关、RDP 主机或服务承载节点。角色描述节点如何被使用，不创建第二个节点身份。
_Avoid_: 节点类型、协议账户、可达性状态

**Workspace Device Profile（工作区设备档案）**：
一个 Node 在 KeyPort 工作区中的设备注册信息，描述它是否是当前设备、拥有哪些工作区密钥以及本机可执行哪些操作。它是 KeyPort 的工作区角色，不是另一台机器身份。
_Avoid_: Host、远端服务器、独立的硬件实体

**Current Device（当前设备）**：
当前正在运行 KeyPort 的 Workspace Device Profile；它是一个本地工作区视角，不是新的 Node 类型，也不代表其他设备的实时状态。
_Avoid_: Node、所有已注册设备、远端服务器

**Endpoint（访问端点）**：
到达某个 Node 或 Service 的网络坐标，至少由地址、端口、协议和网络范围表达，也可以记录来源、优先级及其他路由信息。同一个节点可以拥有多个 IP、域名、局域网地址、公共地址或覆盖网络地址。
_Avoid_: IP、Host、Access Address、SSH 账户

**Network Scope（网络范围）**：
Endpoint 所属的网络语境，例如局域网、公共网络、Tailnet 或 VPN 内部网络；它帮助选择访问路径，但不改变节点身份。
_Avoid_: 可达性状态、VPN 授权、IP 地址

Endpoint 可以记录稳定的网络范围标签，但 Wi‑Fi 名称、网卡、信号强度和当前网络切换属于 Reachability Observation 的环境上下文，不属于 Node 或 Endpoint 的身份。

**Service（服务）**：
运行或承载在某个 Node 上、具有独立访问入口的逻辑能力，例如 PostgreSQL、HTTP 服务或内部 API。服务可以拥有自己的端口、协议和域名，不应被误当成一台机器。
_Avoid_: Host、端口、数据库节点

**External Node Identity（外部节点身份）**：
由 Tailscale 等外部网络系统报告的节点标识；在 Tailscale 中由 `Tailnet + Node ID` 唯一表达，并绑定到一个 KeyPort Node。MagicDNS、Tailscale IP、主机名和操作系统是可更新的最后已知元数据，不是节点身份本身。
_Avoid_: SSH 账户、访问授权、自动发现到的相似名称

**Tailscale Observation（Tailscale 本机观测）**：
某台运行 KeyPort 的 Mac 在某个时间从本机 Tailscale 状态读取到的在线状态、Last Seen、Relay 和刷新时间。它属于观察设备的本地证据，不能覆盖其他 Mac 的状态，也不能删除云端已保存的 Node。
_Avoid_: 全局在线状态、Node 身份、CloudKit 共享事实

**Topology Graph（拓扑图）**：
由工作区事实和当前设备的本地观测推导出的节点、服务及访问关系的可视化投影。Graph 展示事实，不创建新的授权、路由或物理连接事实。
_Avoid_: 数据库、事实源、任意画布连线

**Host（兼容称谓）**：
在用户界面或协议语境中可以表示承担主机角色的 Node，但不再是与 Node 并列的机器身份实体。
_Avoid_: 用 Host 表示单个 IP、端口、SSH 账户或当前 Ping 状态

**Device（非规范核心称谓）**：
在描述硬件或操作系统时可以使用，但 KeyPort 的领域模型中不单独用它表示一台机器。涉及工作区注册时使用 Workspace Device Profile，涉及机器身份时使用 Node。
_Avoid_: 用 Device 区分本机与远端机器

## 访问与安全

**Access Method（访问方式）**：
使用某种协议和凭据到达 Endpoint、Node 或 Service 的方式。当前优先支持 SSH；VPN、RDP 等方式可以作为后续的协议专用访问方式加入，而不改变 Node 的身份模型。
_Avoid_: 授权本身、可达性状态、节点角色

**SSH Account（SSH 账户）**：
某个 Node 上的 SSH 登录入口，由用户名和稳定别名表达；一个 Node 可以有多个 SSH 账户。账户凭据和授权属于账户级访问关系，不属于 Node 的通用元数据。
_Avoid_: SSH Identity、Host、Workspace Device Profile

**SSH Key（SSH 密钥）**：
归属于一个 Workspace Device Profile、由公钥指纹识别的密钥身份；私钥只由持有它的本地设备保管。
_Avoid_: SSH 账户、共享私钥、公钥备注

**Access Authorization（访问授权）**：
某个访问来源使用特定访问方式访问目标账户、Node 或 Service 的允许关系。授权表达“允许使用”，不表达网络可达，也不表达最近一次验证成功。
_Avoid_: Ping、Host Key Trust、登录成功记录

**SSH Authorization（SSH 授权）**：
一个 SSH Key 被某个 Node 上的 SSH Account 接受用于登录的账户级授权关系。
_Avoid_: 设备到主机的永久连接、当前在线状态、Host Key Trust

**SSH Host Key Trust（SSH 主机身份信任）**：
用户针对一个 SSH Endpoint 确认的远端主机密钥身份及其变更历史；它用于防止连接到错误的远端，不等同于账户密码或访问授权。
_Avoid_: SSH Key、账号授权、Ping 状态

**Reachability Observation（可达性观测）**：
某个本地 Node 在特定时间、网络环境和观测方式下对 Endpoint 是否可达的带来源证据。它会过期，也不能被当作 Node 的永久状态。
_Avoid_: Host Ping、全局在线状态、访问授权

**Access Verification（访问验证）**：
某个本地 Workspace Device Profile 在特定时间对 Endpoint、SSH Host Key 和 SSH Account 完成检查后得到的本地证据。它只说明那次验证，不替代同步的授权事实。
_Avoid_: 实时连接、永久授权、Node 状态

**Account Password（账户密码）**：
用于验证并首次建立 SSH Account 访问授权的秘密；它不是 Node、Endpoint 或设备元数据。
_Avoid_: 设备密码、VPN 密码、授权状态

## 工作流

**Enrollment（接入）**：
创建或选择 Node，添加 Endpoint 和 SSH Account，确认 SSH Host Key Trust，并证明账户可控的过程。
_Avoid_: 单纯添加地址、同步、设备授权

**Enable Key Access（启用密钥访问）**：
确保当前 Workspace Device Profile 的 SSH Key 能够登录指定 SSH Account 的用户意图；已有授权时只验证，不存在授权时才安装公钥并复验。
_Avoid_: 免密验证、一键免密、复制私钥
