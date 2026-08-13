# JODER-30 节点关联实现说明

本实现基于 JODER-29《Tailscale 节点与 SSH 端点映射研究》的证据分级，在 KeyPort 本地提供 Test Case 逻辑节点与 Tailscale/SSH 实际节点的自动和人工关联。

## 当前数据源与稳定 ID

- `testCaseNodeId`：由上游 Test Case 系统提供的不透明稳定 ID。KeyPort 不从主机名、IP、SSH alias 或其他本地字段生成它。
- `ServerConnection.id`：KeyPort 内部 SSH 账户 ID，只在本地/CloudKit KeyPort 数据范围稳定，不代替 `testCaseNodeId`。
- 实际节点：`tailscale:{normalizedTailnetKey}:{nodeId}`。`tailnetKey` 小写并移除尾点，`nodeId` 大小写敏感。
- 本地 Tailscale 快照：当前使用 `tailscale status --json`。只有 JSON 中真实 `ID` 字段可作为稳定目标；PublicKey、字典键等 parser fallback 只用于展示，不能自动关联或持久化为目标。
- SSH 有效配置：对 alias 执行既有 `ssh -G -- <alias>` 发现流程，并读取最终 `hostname`、`proxyjump`、`proxycommand` 和 `hostkeyalias`。

## 自动匹配优先级

自动关联仅在以下条件同时成立时发生：

1. `testCaseNodeId`、tailnet 标识和真实 Tailscale `nodeId` 均存在。
2. Tailscale 数据源刷新成功且当前快照完整。
3. SSH 路由为直连，不存在生效的 `ProxyJump` 或 `ProxyCommand`。
4. 最终 SSH `HostName` 与同 tailnet 某节点的 MagicDNS 或 Tailscale IPv4/IPv6 标准化后精确一致。
5. 只有一个稳定节点命中，且没有人工解除抑制或 Host Key 冲突。

`exact_magicdns` 和 `exact_tailscale_ip` 是当前仅有的自动证据。公网/LAN IP、普通 DNS、相似名称、OS、tag、SSH alias、Host Key 和网络可达性不会单独触发自动关联。多候选和代理路由进入待确认；无匹配保持未关联。

## 状态与执行门禁

`NodeAssociation` 状态为 `unlinked`、`pending_confirmation`、`linked`、`review_required` 或 `invalidated`。只有带稳定目标的 `linked` 记录允许关联驱动的 Test Case 执行。

- 人工确认和改绑使用 revision 乐观并发；旧 revision 会被拒绝。
- 解除关联写入 `invalidated` tombstone，并设置 `autoLinkEnabled=false`，刷新不会立即自动绑回。
- 用户明确恢复自动匹配后才重新评估。
- 原 `nodeId` 消失、相同地址出现新 `nodeId`、自动映射的有效 SSH HostName 漂移，或 Host Key 冲突时进入 `review_required`，保留旧目标但阻止执行。
- Tailscale 临时不可用仅记录 `source_unavailable`，不删除目标、不改变原状态，也不推进 `lastVerifiedAt`。

## 持久化与隐私

`AppSnapshot.schemaVersion` 从 4 升至 5，新增 `nodeAssociations`。旧快照兼容解码后执行显式 v4→v5 迁移，初始关联数组为空，不按旧 IP/DNS 猜测回填。

CloudKit 和加密归档同步关联的稳定复合 ID、状态、方法、证据类型、原因码、时间和 revision。合并按 `testCaseNodeId` 选择更高 revision，同 revision 选择较新的 `updatedAt`，所以解除 tombstone 不会被旧 linked 记录复活。

关联记录不包含候选地址、SSH 用户、密码、Token、私钥、原始 `ssh -G` 输出、IdentityFile 或 Host Key 原文。候选名称和现有 Tailscale 快照属性只在当前 UI 会话中展示。

## 当前边界与残余风险

当前仓库没有 Test Case 实体、企业 API、Python 服务或 HTTP 客户端，因此本实现提供本地状态模型、匹配器、人工管理 UI、持久化和可供未来执行入口调用的 `canExecuteTestCaseNode` 门禁，但不声称已经接通真实 Test Case 加载或运行流程。真实接入仍需上游提供稳定 `testCaseNodeId`、授权范围和版本化 API 契约。

本地 Tailscale CLI JSON 不是长期稳定协议。parser 对未知字段保持容忍，但 Tailscale 升级后仍需复核 `ID`、DNS 和地址字段语义。CloudKit 的真实双设备并发需要带 entitlement 的签名构建和两个 iCloud 客户端做补充集成验证。

## 测试覆盖

`KeyPortCoreTests/NodeAssociationTests.swift` 覆盖唯一 MagicDNS、IPv6、无命中、多候选、代理路由、fallback ID、人工确认、revision 冲突、解除抑制、nodeId 重建、端点漂移、数据源不可用、v4→v5 迁移、敏感字段边界、tombstone 合并和 `ssh -G` 路由字段解析。`script/test.sh` 会运行全部 XCTest、原有 CoreChecks 和 AskPass FIFO 集成检查。
