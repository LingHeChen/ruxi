# CloudBase HTTP SQL 数据层

2026-10-10 已接入生产云托管，所有业务数据位于 `ruxi` schema。共享 PostgreSQL 无需标准 PG 协议连接，服务端通过官方 `/v1/rdb/exec-pgsql` 访问，API Key 不进入前端。

## 实现

- `Ruxi.CloudSQL`：HTTPS SQL 传输、参数编码、脱敏错误及批处理调用。
- `Ruxi.CloudDB`：乐观事务单元，读取观察与写入计划、事务内预演、提交校验、冲突重试及稳定 UUID 提交回执。
- `Ruxi.DB`：原生 PostgreSQL 与 HTTP 模式共用的业务接口；JSON/bytea 显式编码；广播提交后执行。
- `Ruxi.CloudMaintenance`：HTTP 模式维护调度，替代依赖原生连接的 Oban。
- `Ruxi.CloudStorage`：私有对象上传/下载/分页/删除，容器目录仅缓存。

## 云端迁移

1. `20261010134000_ruxi_http_batch.sql`：单请求原子 SQL 批处理。
2. `20261010145000_ruxi_business_increment.sql`：业务 005–022 增量，迁移头 `20261010002200`。
3. `20261010150000_ruxi_http_transactions.sql`：HTTP 事务预演、读取校验、写入提交及幂等回执。

HTTP 事务函数通过共同写锁串行提交，并在同一事务校验观察结果。不得将需要事务的业务拆成多个独立 HTTP 写入。冲突会重新读取和计算，外部副作用只能在提交后执行。函数撤销 PUBLIC 执行权限，业务表拒绝匿名/普通前端角色访问。

## 已验证和限制

此前通过 HTTP 模式 147 项测试、真实云库并发四人业务、失败回滚和幂等行为验证，线上 AI 任务已完成。房间定时维护减少无效租约写入、扩大 HTTP 连接池，避免与玩家命令持续争用；Cloud SQL 故障转成 503。

客户端保留不确定命令，恢复时查询回执；没有回执则重放同一编号和完整信封，不能生成新编号掩盖不确定提交。上线地址及 `/api` 转发规则见 [部署记录](CLOUDBASE.md)。

用户要求暂缓完整回归和游玩验收，本次前缀/域名/待确认命令修复完成构建与发布检查，尚未重新执行完整线上多人、RTC 与灾备流程。

## 2026-10-10 指令数据库往返优化

继续使用现有套餐的 HTTP SQL，不切换原生连接。命令入口把房间、会话、成员、幂等回执和语音过渡检查合并为一次预演请求；事务内缓存仅在当前事务存在，已知无跨表副作用的写入只失效相关表的读取，未知写入和 DELETE 全量失效。最终提交仍校验全部观察结果。

成员视图序号采用一次批量 UPDATE 和一次有序 SELECT，替代逐成员 UPDATE RETURNING；命令回执复用这些序号。保留提交后广播和同编号幂等重试。

C2 HTTP 响应增加 Server-Timing，包含 app、db 毫秒耗时和 db_calls 次数，不包含 SQL、参数或凭据。Cloud SQL 暂时故障返回可重试的 503。

本轮关键回归：HTTP SQL 路径 18 项、原生路径 10 项全部通过；未运行完整游玩、RTC 或并发负载验收。

## WS 指令与即时视图修复（2026-10-10）

上轮 Core 008 只优化 HTTP 数据层，Flutter 游戏指令仍 POST /commands，成功后 GET snapshot，未完成 WS 切换。本轮 C2Client 改为 Phoenix `room.command`，以 ref 匹配回执，业务拒绝不关闭连接。超时/断线保留 command_id 与信封；恢复查回执，缺失时经 WS 重放原信封。正常提交依据 receipt_seq 等待 room.view，只有推送缺失才回退快照同步。交互报价经 `interaction.quote`，HTTP 接口保留兼容旧客户端。

CloudBase 模式在事务提交后立即广播授权成员视图；持久化 outbox 继续补发，客户端按 stream/seq 去重。原生模式因 after_commit helper 未延迟回调，继续使用提交后的 outbox drain，避免提交前广播。已观察写入不再无差别清空事务缓存；save_ready 复用已读取的房间和成员，视图序号从已验证成员快照计算并批量递增，不再额外 SELECT。

实测（独立测试房间、小样本）：Core 008 的 WS member.ready 回执 1232/1578ms，视图 6296/6212ms；Core 009 回执 706/709ms，视图 785/1157ms，数据库请求 6 次；同编号重试数据库请求 2 次。游戏内 media.complete 回执 1081/1486ms，action.submit 回执 1342ms、视图 1542ms，数据库 8 次；room.start 为 1823ms、11 次。样本受公网网络和当时负载影响，不是延迟 SLA。

覆盖：Flutter 本地真实 WebSocket 测试验证回执/推送两种顺序、无 HTTP command POST 或成功后 snapshot、业务拒绝保活、断线后同编号 WS 恢复、WS 交互报价；HTTP SQL 18 项和原生 10 项关键业务回归通过。线上 Node WebSocket 验证回执、视图和重放序号一致。未进行完整 RTC/并发负载验收。
