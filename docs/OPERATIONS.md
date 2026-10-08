# 运行与恢复

部署配置仍待云端验证，以下是本地已实现的运行流程。业务 SQL、Oban 和迁移均位于 `ruxi` schema。

## 进程与持久卷

管理员签发码使用 `mix run --no-start priv/repo/admin_code.exs USER_ID editor reviewer publisher`，只启动数据库依赖，避免短命 CLI 启动第二个 outbox Dispatcher。

Core 固定单实例；上线前配置 HTTPS/WSS 代理，保留升级头，空闲超时高于 25 秒心跳。运行账户使用单独的 SQL DML 角色，迁移账户执行 DDL；参考 `services/core/priv/repo/runtime_permissions.sql`。CloudBase 当前数据库角色无法自行创建角色，实际授予由平台管理员配置，不能重置共享密码。

本机启动使用 `scripts/start_core.sh`，将文件句柄上限设为 4096。初次 100 房测试在 macOS 默认 256 限制下出现 `emfile`，不能只提高应用连接上限。云托管需确认运行容器的实际限额。

`ERASURE_LEDGER_PATH` 和 `OBJECT_ROOT` 必须是持久卷的绝对路径。注销台账必须独立于数据库恢复点保留。对象目录采用随机 UUID、不可覆盖的内容校验写入；不接受客户端路径。上传源文件默认 15 分钟有效，500 MiB 上限。

生产 AI 与媒体使用不同 Worker 身份和服务。AI 仅领取 player_hint/editor_ai；媒体仅领取 media_transcode，且不提供模型密钥。媒体进程非 root，固定 FFmpeg 参数；禁用网络协议及播放列表容器，限制 CPU 300 秒、墙钟 600 秒、输出 500 MiB、文件句柄 64、Linux 地址空间 1 GiB；子进程环境不继承模型或任务凭证。这些限制不等同于完整内核沙箱，生产仍需容器资源、网络和文件系统隔离。

## 调度与监控

离线挂起及终局房间会释放 resident 进程与 owner 租约；重新进入按 SQL 事实接管。广播恢复扫描只包含 running/paused，并按固定 5 秒间隔执行，不能重新唤醒所有历史 suspended 房间。Oban 对没有 owner 的过期房间做有界清理，避免历史房间每秒占用数据库连接。

Oban 使用独立 schema 前缀，每分钟安排有界维护，最多 3 次生产任务 attempt；过期重领达到上限后失败隔离。每 15 秒续租，失去租约立即取消计算，不再提交输出。完成回执绑定 attempt、租约摘要与结果摘要；重试回放既有回执。

制作台「运营概览」只读已提交房间结果及聚合运行指标，不读取私有线索、提示、聊天、个人投票或玩家标识。`GET /v1/admin/operations` 仅 reviewer 可用。建议告警：待发送 outbox 最长年龄超过 5 秒、持续增长、任务失败率上升、内存持续增长、备份完成时间超过 5 分钟未更新；云平台告警尚待部署配置。

终局汇总与原事务一并写入；保存 180 天。正文/诊断和建议 7 天、账号回执 30 天；媒体成功输出保留引用，过期 attempt 文件及编辑提案由维护任务回收。活动/挂起房间不按年龄删除。

## 备份与恢复

`scripts/backup.sh` 通过 `DATABASE_URL` 连接，使用 `BACKUP_ROOT` 独立目录，成功后原子写入 `latest-completed`；备份文件权限 600。调度每 5 分钟运行并监测备份耗时，生产数据库还需启用平台备份/PITR；不能将同盘副本当异地备份或把计划数字当 SLA。

恢复步骤：停止外部写入与 Worker → 恢复独立数据库 → 挂载最新独立注销台账 → 设置全新 `RECOVERY_EPOCH` → 在关闭公共应用的恢复库上设置 `RECOVERY_CONFIRMATION=RESET_RESTORED_DATABASE`，执行 `mix run --no-start priv/repo/recover_database.exs`（撤销会话/刷新/票据、清空认证及领取缓存、清除租约、递增房间 owner_epoch）→ 台账重放 → 验证权限/约束 → 单 Core 启动 → Worker 启动 → 通过恢复码重新认领 → 检查新 epoch 触发客户端快照修复 → 放开入口。

正式控制脚本拒绝公共应用运行时执行，检查新 epoch 与旧投影不同，同时丢弃旧投影并推进 replay floor。`restore_verify.exs` 仅做演练断言，供 `restore_drill.mjs` 使用。演练只连接独立数据库；不会撤销当前开发库的全部会话。

本机恢复、强制崩溃及负载结果见 `VALIDATION.md`。尚未验证 CloudBase 的异地备份、持久卷、TLS 代理、容器启动及告警。

## 正式账号与后台角色

玩家在个人空间注册账号，游客升级保留 user_id、房间和收藏。密码使用随机盐与 600,000 轮 PBKDF2-SHA256 摘要，账号名不区分大小写；注册、登录、密码恢复受失败预算限制。注册后保存恢复码，用于没有邮件/短信基础设施时的密码找回；重置撤销旧会话并轮换恢复码。这里不声称已实现邮件验证或短信认证。

管理员可运行 `mix run --no-start priv/repo/admin_code.exs <已注册账号名> editor reviewer publisher` 为现有账号授权，随后使用账号密码登录制作台；原 UUID 与一次性码方式仍可用。普通注册用户没有后台权限。发布角色可在用户目录分配后台角色，变更撤销目标的已有后台会话并写入审计；不允许在该界面移除自己的发布角色。注销删除账号密码摘要、简介和收藏，并沿用独立擦除台账。
