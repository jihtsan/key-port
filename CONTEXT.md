# KeyPort Domain Context

KeyPort describes a personal SSH access topology: which devices, remote resources, services, identities, and grants belong together. This glossary keeps persisted facts separate from device-local observations and from their visual projection.

## Workspace

**Workspace（工作区）**:
一个用户维护的 KeyPort 数据集合，包含设备、远端资源、访问配置、公开身份和拓扑关系。
_Avoid_: 账户、项目、集群

## Topology

**Device Node（设备节点）**:
一台注册到工作区、拥有独立 SSH 身份的用户设备；同一台物理设备在工作区中只有一个稳定身份。
_Avoid_: 本机、客户端、Mac 节点

**Remote Resource（远端资源）**:
用户希望管理的一个逻辑远端计算资源，例如服务器、虚拟机、NAS 或网络设备；它独立于具体登录地址和账号存在。
_Avoid_: ServerConnection、服务器连接、主机

**Hosted Service（托管服务）**:
运行在某个远端资源上的命名能力，例如 PostgreSQL、Redis、Web 应用或文件服务。
_Avoid_: 服务器、SSH 连接、进程

**Topology Relation（拓扑关系）**:
两个远端资源或托管服务之间由用户确认的逻辑关系，例如托管或依赖；它不自动表示网络可达或流量路由。
_Avoid_: 连线、网络路由、授权

**Topology Graph（拓扑图）**:
由工作区事实和访问观测推导出的设备、远端资源、托管服务及其关系的可视化投影。
_Avoid_: 数据库、事实源、画布数据

## Access

**Access Profile（访问配置）**:
一个账号级 SSH 入口，描述如何以特定主机、端口、登录账号和稳定别名访问某个远端资源。
_Avoid_: ServerConnection、服务器、节点

**Host Identity（主机身份）**:
用户为一个访问配置确认并信任的 SSH Host Key 指纹集合。
_Avoid_: 服务器密码、设备密钥、普通状态

**SSH Identity（SSH 身份）**:
归属于一个设备节点、由公钥指纹唯一识别的 SSH 密钥身份；它的私钥部分只属于该设备。
_Avoid_: 共享密钥、密钥文件、公钥备注

**Key Grant（密钥授权）**:
某个访问配置对应的远端账号允许某个 SSH 身份登录的关系。
_Avoid_: 免密、连接状态、设备授权状态

**Credential Proof（凭据证明）**:
用户通过密码或已经生效的 SSH 身份证明其能够控制某个远端账号的结果。
_Avoid_: 保存密码、授权、连通性检测

**Access Observation（访问观测）**:
某个设备节点在特定时间对可达性、主机身份、密码认证或密钥认证进行检查后得到的带来源证据。
_Avoid_: 全局状态、授权事实、同步状态

**Enrollment（接入）**:
创建或选择远端资源、建立访问配置、确认主机身份并取得凭据证明的过程。
_Avoid_: 添加服务器、免密授权、同步

**Enable Key Access（启用密钥访问）**:
确保当前设备的 SSH 身份能够通过指定访问配置登录的用户意图；已有授权时只验证，不存在授权时才新增密钥授权。
_Avoid_: 免密验证、一键免密、复制密钥
