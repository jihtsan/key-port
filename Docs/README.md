# KeyPort 文档导航

## Graph 改版提案

以下文档定义 Issue [#26](https://github.com/jihtsan/key-port/issues/26) 的目标方向：

1. [领域词汇](../CONTEXT.md)：统一 Node、节点角色、工作区设备档案、Endpoint、SSH 账户、服务、授权和本地观测。
2. [网络拓扑领域模型重构设计](./网络拓扑领域模型重构设计.md)：定义全量重构的 Node/Role/Profile/Endpoint 边界、SSH 第一阶段和 VPN/RDP/服务扩展位置。
3. [ADR 0002：统一 Node 身份并分离访问事实](./adr/0002-unify-node-identity-and-separate-access-facts.md)：记录 Host/Device 合并为统一机器身份、访问事实保持独立的架构决策。
4. [Graph 拓扑与跨设备授权架构](./Graph拓扑与跨设备授权架构.md)：记录当前 Host v6 Graph 投影、接入/授权流程、多设备场景和 iCloud 边界；实体边界重构时以新领域模型为准。
5. [整体重构与迁移计划](./整体重构与迁移计划.md)：记录当前 Host v6 写权切换、旧 UI 删除门槛和实施阶段；后续实现阶段需按新领域模型调整。
6. [ADR 0001：Graph 是 Host v6 访问事实的投影](./adr/0001-graph-is-a-projection-of-access-facts.md)：记录不创建第二套 Graph 事实源的历史决策。

新的领域模型文档既是全量重构的设计基线，也是当前 V1 实现基线。默认 Graph 已从 `topology-v1.json` 的统一快照投影；Graph 架构和整体重构计划中的 Host v6 实体关系只保留为迁移、Cloud、SSH 和恢复适配器的历史证据，不应继续作为新实体的设计依据。涉及安全、同步、迁移和隧道的既有契约仍需在代码重构时逐项迁移和验证。

## 当前承重架构与实现证据

- [主机工作台技术架构与迁移契约](./Design/JODER-10/host-workbench-architecture.md)：Host v6、CloudKit v2、写权、迁移、地址、服务和隧道的承重口径。
- [APP 功能全景与产品 Review](./APP-功能全景与产品Review.md)：当前页面、端到端流程、重复入口和产品缺口。
- [JODER-30 节点关联实现说明](./JODER-30-节点关联实现说明.md)：SSH 账户与 Tailscale 实际节点的证据和门禁。
- [Tailscale SSH 端点映射研究](./Tailscale-SSH-端点映射研究.md)：实际节点匹配的证据分级。
- [iCloud 配置与签名](./iCloud-配置与签名.md)：CloudKit/iCloud Keychain 的签名与运行要求。
- [JODER-43 验收报告](./Design/JODER-43/acceptance-report.md)：相关 UI/验收证据。

## 产品与技术基线

- [SSH KeyPort 一期需求规格](./SSH-KeyPort-一期需求规格.md)
- [一期实现架构与验证说明](./一期实现架构与验证说明.md)
- [SSH 技术原型结论](./SSH-技术原型结论.md)
- [macOS 技术框架与组件选型](./macOS-技术框架与组件选型.md)
- [根 README](../README.md)
- [当前界面设计基线](../DESIGN.md)

## 阅读顺序

- 想理解新方向：领域词汇 → 网络拓扑领域模型重构设计 → ADR 0002 → Graph 架构 → 整体重构计划。
- 想实现 Graph：先读 JODER-10 第 5-10 节，再读 Graph 架构第 3-10 节。
- 想改接入或免密流程：先读 APP Review 第 4、10、11 节，再读整体计划第 5、7、8 节。
- 想改同步或数据模型：先读网络拓扑领域模型重构设计，再以 JODER-10 和当前 Host v6 代码核对迁移契约；Graph 文档只定义投影和 UI 消费方式。
- 想了解当前运行版本：读根 README、APP Review 和一期实现架构说明。
