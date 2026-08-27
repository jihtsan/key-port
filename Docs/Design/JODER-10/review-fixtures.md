# JODER-10 独立评审复现 fixture 与判定矩阵

本文件是 `host-workbench-architecture.md` revision 2 的可执行复审入口。它固定输入和期望，不代替后续 XCTest；实现若与本矩阵不一致，应先修改实现或重新评审架构，不能在测试里另定语义。

## 1. 生成 v5 输入

```sh
fixture_dir="$(mktemp -d)"
swift Docs/Design/JODER-10/fixtures/generate-review-fixtures.swift --output-dir "$fixture_dir"
jq '.servers | length' "$fixture_dir/v5-a10-b1.json"
jq '.auditEvents | length' "$fixture_dir/v5-a10-b1.json"
jq '.expected' "$fixture_dir/manifest.json"
```

预期前两条 `jq` 分别输出 `2` 与 `1000`。生成器只写调用方给出的目录；fixture 中的 private key path 是不可用的标记文本，不读取 Keychain、SSH 或网络。

| 文件 | 变化 | 用途 |
| --- | --- | --- |
| `v5-a10-b1.json` | A version 10；B version 1；两者规范化为同 endpoint | 初次迁移、Pin/raw-line multiplicity、完整资产迁移 |
| `v5-a10-b2.json` | 只把 B 升到 version 2，修改 alias/status/notes 并增加 B 专属 ECDSA Pin | 多对一派生实体的逐 source 因果与重复导入 |
| `v5-a10-b3-deleted.json` | 只把 B 升到 version 3 并 tombstone | source 删除、共享 Host/Pin 保留和 B 专属来源收口 |

## 2. 初次迁移 M1

输入：`v5-a10-b1.json`。

| 断言 | 精确预期 |
| --- | --- |
| Host/Address/Identity | 1 Host、1 Address、2 Identity；Identity ID 分别等于 A/B 的旧 ServerConnection UUID |
| Host legacy vector | `{legacy-v1/server/11111111-1111-4111-8111-111111111111: 10, legacy-v1/server/22222222-2222-4222-8222-222222222222: 1}` |
| Credential inventory | 1 Device、1 SSHKeyRecord；ID 与 v5 完全相同，key.deviceID 可解析 |
| Credential legacy vector | Device 为 `{legacy-v1/device/device_review_fixture: 1787616000000}`；Key 为 `{legacy-v1/key/key_review_fixture: 1}` |
| Authorization | 1 条；sshIdentityID 为 B ID、keyID 为 `key_review_fixture`，两处引用均可解析 |
| NodeAssociation | 1 条；ID 为 `database-b.review.example`、sshIdentityID 为 B ID、revision 为 1，target 逐字段保留 |
| Audit | local partition 恰好 1000 条，UUID/顺序/字段逐项相等；Cloud/archive 均为 0 |
| Identity local state | A/B 的 status、statusDetail、passwordCheck、keyCheck、lastCheckedAt 逐字段存在；notes 分别保留 A/B 来源 |
| Pin | 2 个逻辑 Pin：shared Ed25519 与 shared RSA |
| KnownHostsLine | 4 条 provenance：A/B 各 2；其中 RSA raw line 字节相同但 provenance 数量仍为 2 |
| known_hosts 派生 | `sorted(unique(rawLine))` 共 3 行；与当前 `HostKeyService` 文件语义相等 |
| Keychain/文件 | 迁移器对 Keychain 写调用为 0；fixture private path 只做映射比较，不访问文件 |

M1 重复执行三次，排序后 state-v6 bytes、每个 mutationID、MergeReview ID/数量必须完全相等。

## 3. 逐 source 因果 M2

先导入 `v5-a10-b1.json`，再导入 `v5-a10-b2.json`。

| 场景 | 预期向量/结果 |
| --- | --- |
| 无 v6 用户写 | Host/Address vector 从 `{A:10,B:1}` 变为 `{A:10,B:2}`；B Identity 为 `{B:2}`；B alias/status/Pin 变化被处理，不能因 A=10 被忽略 |
| 重复导入 B2 | output hash、mutationID、review count 不变 |
| B2 同 version、不同 synced digest | 返回 blocking `legacyVersionReuse`；保留既有实体，不按 updatedAt 覆盖 |
| 在 B1 后有 v6 device X mutation | 当前 `{A:10,B:1,device/X:1}` 与 B2 `{A:10,B:2}` 互不支配；创建一个确定性 MergeReview，不覆盖任一候选 |
| 解决并再次同步 B2 | resolution vector join 全部候选并递增当前 device；相同 B2 不重新打开 review |

## 4. source 删除 M3

在 M2 后导入 `v5-a10-b3-deleted.json`：

- Host 与 Address 仍 active，因为 A 是 active contributor。
- B Identity tombstone；B 的 Authorization/NodeAssociation 按 5.5 的 relation cascade 收口为墓碑，Authorization 保留远端状态且不伪称已撤权。
- B 的三条 KnownHostsLine provenance tombstone；A 的两条仍 active。
- shared Ed25519/RSA Pin 因仍有 A 来源而 active；B 专属 ECDSA Pin 因无 active 来源而 tombstone。
- A Identity、Device、SSHKeyRecord 和 1000 条本机 AuditEvent 不变。
- 重放 B3 不新增 tombstone mutation 或 review。

## 5. Cloud / archive allow-list M4

使用 M1 的 v6 envelope 做 local、Cloud、archive 三次编码：

| 字段/实体 | Local | Cloud v2 | Archive v2 |
| --- | --- | --- | --- |
| Device synced fields | 1 | 1 | 1 |
| Device.isCurrent | 当前 Mac 派生 | 缺失 | 缺失 |
| SSHKeyRecord synced fields/publicKey | 1 | 1 | 1 |
| privateKeyPath/isInAgent/isLocallyAvailable | 保持 v5 local 值 | 缺失 | 缺失 |
| Authorization.keyID | `key_review_fixture` | 同值 | 同值 |
| NodeAssociation | 1 | 1 | 1 |
| AuditEvent | 1000 | 0 | 0 |
| LegacySourceRevision/authority manifest | 完整 | 脱敏后存在 | 存在 |

把 Cloud payload 合回 M1 local envelope 后，private path/agent/current-device overlay 和 1000 条 AuditEvent 必须从 local 恢复。对序列化 bytes 扫描 fixture private path、AuditEvent result 与 `isCurrent`，Cloud/archive 必须零命中。

## 6. 删除事务 M5

每行分别注入“atomic replace 前失败”“replace 后派生 step 失败”“同 commandID 重放”：

| 命令 | replace 前失败 | replace 后失败 | 重放 |
| --- | --- | --- | --- |
| deleteHost | 旧 snapshot 完整保留 | 模型 cascade 全部可见，journal 标记 config/credential/tunnel pending；未确认远端 revoked 的关系返回 committed + `remoteAuthorizationMayRemain` | 不新增向量，继续未完成 step |
| deleteIdentity | Identity/Auth/NodeAssociation 同事务全有或全无 | Identity 墓碑保持，Keychain/config pending；未确认远端 revoked 时返回 committed + `remoteAuthorizationMayRemain` | 同结果 |
| deleteAddress | 引用 policy 缺失或 replacement 非法时稳定拒绝；不会部分清引用 | `.clear`/`.replace` 已按调用方选择提交，Pin/line 已 tombstone，known_hosts cleanup pending | 同结果 |
| retireSSHKey | active Authorization 存在时 `keyStillAuthorized`，snapshot 不变 | key 墓碑保持，私钥删除 pending | 同结果 |
| revokeAuthorization | 远端失败时 snapshot 不变 | 远端成功后模型写失败必须以 remote-result journal 恢复，禁止重复撤销造成误报 | 同 remote result 收口一次 |
| clearAuditEvents | atomic replace 前仍为 1000 条 | replace 后恰为 0；不写 Cloud/archive/history | 同 commandID 保持 0，不新增 clear AuditEvent |

每个成功 snapshot 都必须通过“无 active 子实体引用 tombstone Host/Identity/Address”和“keyID/deviceID 可解析”检查。

## 7. 地址 continuation M6

| 场景 | 预期 |
| --- | --- |
| 固定地址失败、两个备选已验证 | 返回 token + 两条 evidence；operation 仍 inflight |
| resume 选择 evidence 中地址 | 同 operationID 返回 selected，消费 token，只写一条终态 |
| resume 传第三个地址 | `invalidAddressChoice`，消费 token，不自动 probe/选择 |
| token 超过 30 秒 | `addressChoiceStale`，消费 token |
| networkEpoch 或 Host mutationID 改变 | token 立即 stale，旧 evidence 不复用 |
| 重复合法 resume/cancel | 返回第一次缓存终态，不新增 ConnectionRecord |
| 应用在 WaitingForUser 终止 | 启动恢复为一条 `interruptedByPreviousTermination` |

## 8. 隧道目标与清理 M7

使用 fake listener、fake broker 与隔离 sshd/target。`ForwardEstablished` 在所有行都不是成功终态。

| 场景 | 状态与稳定码 | 保存/清理预期 |
| --- | --- | --- |
| NWListener.cancel 延迟 500 ms | `.cancelled` 前 spawn count 为 0；之后才 StartingForward | 不泄漏 reservation listener |
| 2 秒未收到 `.cancelled` | `localPortReleaseTimeout` | ssh spawn count 0；listener 继续被持有到最终 cancelled |
| ssh bind/master 成功，target 立即拒绝 | ForwardEstablished -> VerifyingTarget -> failed `targetConnectionRefused` | 无 TargetVerificationEvidence、候选不可保存；master/broker/socket/lease 全清 |
| target 黑洞超过 5 秒 | failed `targetConnectionTimeout` | 同上 |
| DEBUG1 格式不在 recognizer fixture | failed `targetProbeIndeterminate` | fail closed，不把 local NWConnection.ready 当成功 |
| probe 对应 direct-tcpip open-confirm | probe 关闭后 Active + 30 秒 TargetVerificationEvidence | 仅完全匹配 operation + discovery session/candidate + identity/address/remote digest/epoch 的确认动作可保存；保存成功后 registry 才 adopt 为 serviceID |
| target failure 且 ControlMaster exit 超时 | primary target code + cleanup `cleanupPending` | TERM/KILL 后保留具名 lease 供下次 reaper；历史 primary code 不被 cleanup 覆盖 |
| Active 后主应用 SIGKILL | broker stdin EOF | 2 秒内端口关闭，lease 清除或由下次 reaper 精确接管 |

## 9. authority / 回滚 M8

| 场景 | 预期 |
| --- | --- |
| C3 未覆盖一个 active Device | 不签 authority manifest，v5 继续唯一写入 |
| C3 完成但 compat semantic diff 失败 | `authorityGateFailed`，仍在 V6Canary |
| 首个 v6 mutation 前撤回 | v1 hash 未变时可回 V6Canary/LegacyAuthoritative |
| 首个 v6 mutation 后请求旧备份可写回滚 | `binaryDowngradeUnsafe`；旧备份不取得写权 |
| 首个 v6 mutation 后功能回退 | 由最新 checkpoint 生成只读 state-v1-compat；v6-only 对象列入 notRepresentable 且仍在 state-v6 |
| compat 期间尝试编辑 metadata | 稳定拒绝；Cloud v1/v2 均不写，连接历史仍可本机 finish |
| 前向恢复 | 校验 checkpoint/current v6 hash 后回 V6Authoritative，identity/key/alias/Keychain 定位不变 |

M1-M8 全部通过，才可认为 JODER-10 revision 2 对本轮独立评审 blocker 提供了可实现且可复现的闭合口径。
