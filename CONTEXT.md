# KeyPort

KeyPort manages a personal SSH access topology: the hosts and services a user manages, the accounts exposed by those hosts, and the device keys authorized for those accounts.

## Topology

**Workspace（工作区）**:
一个用户维护的 KeyPort 数据集合，包含主机、访问地址、SSH 账户、KeyPort 设备、密钥、服务和授权关系。
_Avoid_: 账户、项目、集群

**Host（主机）**:
一个稳定的物理机或虚拟机对象；同一主机可以拥有多个访问地址、SSH 账户和服务。
_Avoid_: ServerConnection、SSH 账户、地址、服务

**Access Address（访问地址）**:
KeyPort 可用于到达某个主机的规范化网络地址和 SSH 端口；同一主机可以拥有手工、覆盖网络或发现来源的多个地址。
_Avoid_: 主机、SSH 账户、授权

**Saved Service（已保存服务）**:
用户确认并保存在某个主机上的 HTTP、HTTPS 或 TCP 服务入口。
_Avoid_: 主机、SSH 账户、自动发现候选

**Actual Node（实际节点）**:
由外部网络数据源报告、具有稳定身份的真实网络节点。
_Avoid_: KeyPort 设备、SSH 账户、仅有相似名称的机器

**Node Association（节点关联）**:
一个 SSH 账户与一个实际节点之间由强证据或用户确认建立的映射。
_Avoid_: 授权、可达性、模糊名称匹配

**Topology Graph（拓扑图）**:
由工作区事实和本地访问证据推导出的 KeyPort 设备、主机、服务及其关系的可视化投影。
_Avoid_: 数据库、事实源、任意画布连线

## SSH Access

**SSH Account（SSH 账户）**:
某个主机上的账号级登录入口，由主机、SSH 用户和稳定别名共同表达；密码和授权始终属于具体 SSH 账户。
_Avoid_: SSH Identity、Host、KeyPort 设备、机器授权

**KeyPort Device（KeyPort 设备）**:
一台注册到工作区并拥有自己 SSH 密钥的用户设备。
_Avoid_: Host、实际节点、远端服务器

**Current Device（当前设备）**:
当前正在运行 KeyPort、持有本地 SSH 私钥的 KeyPort 设备。
_Avoid_: Host、远端设备

**SSH Key（SSH 密钥）**:
归属于一个 KeyPort 设备、由公钥指纹唯一识别的 SSH 密钥身份；私钥只属于持有它的设备。
_Avoid_: SSH Identity、SSH 账户、共享私钥、公钥备注

**Host Trust（主机信任）**:
用户针对一个主机访问地址确认的 SSH Host Key 身份及其历史。
_Avoid_: 账号密码、设备密钥、网络可达性

**Account Authorization（账户授权）**:
某个 KeyPort 设备的 SSH 密钥被一个 SSH 账户允许登录的关系。
_Avoid_: Local Authorization、设备授权、节点关联、Tailscale 授权

**Account Password（账户密码）**:
用于验证并首次建立一个 SSH 账户授权的秘密；它不是主机或设备元数据。
_Avoid_: 设备密码、Tailscale 密码、授权状态

**Access Observation（访问观测）**:
当前设备在特定时间对可达性、主机信任或账号认证进行检查后得到的带来源证据。
_Avoid_: 全局状态、同步事实、账户授权本身

**Enrollment（接入）**:
创建或选择主机、建立 SSH 账户、确认主机信任并证明账号可控的过程。
_Avoid_: 单纯添加地址、同步、设备授权

**Enable Key Access（启用密钥访问）**:
确保当前设备的 SSH 密钥能够登录指定 SSH 账户的用户意图；已有授权时只验证，不存在授权时才安装公钥并复验。
_Avoid_: 免密验证、一键免密、复制私钥
