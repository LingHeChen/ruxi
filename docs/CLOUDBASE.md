# CloudBase 部署记录

2026-10-10，目标环境 `tnt-like-d2gmmbwti62706aae`，地域 `ap-shanghai`。项目为 MIT 许可求职作品。

## 服务与地址

- 后端：`https://ruxi.fuyaten.online`，云托管服务 `ruxi-core`（Elixir OTP release，4000 端口，固定单实例）。
- 玩家端：`https://ruxi-player-tnt-like-d2gmmbwti62706aae.webapps.tcloudbase.com`，Flutter Web。
- 管理端：`https://ruxi-admin-tnt-like-d2gmmbwti62706aae.webapps.tcloudbase.com`，React + TypeScript + Vite + Ant Design + React Flow。
- AI、媒体 Worker：`ruxi-ai-worker`、`ruxi-media-worker`，Python 云托管。Worker 主动领取任务，不需要公开 HTTP 入口。

## API 与路径转发

全部后端入口统一位于 `/api`：

| 用途 | 路径 |
| --- | --- |
| 健康状态 | `/api/health` |
| 账号、用户及原 V1 业务 | `/api/v1/*` |
| C2/C3 创作及游玩 | `/api/v2/*` |
| Worker 任务 | `/api/internal/work/*` |
| 签名上传、预览、媒体 | `/api/uploads/*`、`/api/asset-preview/*`、`/api/media/*` |
| Phoenix WebSocket | `/api/socket/websocket` |

CloudBase 自定义域名 `/api` 路由转发到 `ruxi-core`，`EnablePathTransmission=true`，保留完整前缀。反向代理必须支持 WebSocket Upgrade。`PUBLIC_API_URL`、前端 `API_BASE` / `VITE_API_BASE`、Worker `CORE_URL` 均配置为根地址 `https://ruxi.fuyaten.online`，不要重复追加 `/api`；代码负责拼接完整接口路径。

自定义域名证书和 DNS 已绑定。域名根路径现有玩家站点路由予以保留。后端 CORS 白名单包含自定义域名和两个前端域名。

## 数据和对象

共享型 PostgreSQL 使用官方服务端 HTTP SQL API，全部业务表和 HTTP 事务辅助函数位于独立 `ruxi` schema。业务迁移已到 `20261010002200`，另有 HTTP 批处理和事务迁移。运行时不需要原生 PostgreSQL 密码、DATABASE_URL、数据库 VPC 或 CFS。生产启动不自动迁移或写入种子。

`DB_BACKEND=cloudbase` 启用乐观事务适配器，观察读取、预演写入、冲突校验及最终提交由 PostgreSQL 函数在事务内处理。提交回执支持网络超时后的幂等查询/重试，广播和外部清理延后至提交后。HTTP 模式不启动 Repo/Oban，维护任务由监督进程执行。详见 [HTTP SQL 重构记录](CLOUDBASE_HTTP_SQL.md)。

私有存储 `ruxi-private` 使用 CloudBase PG 云存储，单文件限制 256 MiB，客户端默认拒绝读写，下载/上传通过业务授权接口。`OBJECT_ROOT=/tmp/ruxi-objects` 只是按需恢复的容器缓存；注销台账持久化在私有对象存储。API Key、RTC 和模型密钥仅注入服务端，私密本地配置位于 Git 忽略的 `.local`，不得复制到源码包或前端产物。

## 发布方式

`scripts/prepare_cloudbase_source.py` 生成白名单源码包，使用 `infra/core.cloudbase.Dockerfile`，携带依赖源码及构建工具，避免远端下载 Hex/Rebar 失败。包内不包含本地凭据。

前端分别部署在共享托管存储的 `/ruxi/admin`、`/ruxi/player`，通过各自域名路由映射到站点根。禁止向共享 `/` 上传，避免覆盖环境中其他应用。SPA 回退规则同时匹配各自导航前缀与 HTTP 404；缺失 JS/CSS 等资源保留 404。页面刷新保留原 URL。

## 验证范围与当前修复

此前已完成：原生业务 142 项测试、HTTP SQL 模式 147 项测试、Python Worker 29 项测试；真实云库四人创建/加入/开局、聊天和票据流程；线上登录、目录读取、AI 任务及两个前端页面加载。线上完整 WebSocket 多人流程曾出现 HTTP 500，不能据此声称完整生产验收通过。

本次修复：房间后台无操作 tick 不再每秒写入所有者租约，减少玩家提交冲突；HTTP 连接池扩容；Cloud SQL 异常返回明确 503。客户端待确认操作查询不到回执时会使用原编号重发，避免一直锁住叙事与行动，也避免重复扣行动点。

按用户最新要求暂停完整游玩和回归测试。本次仅完成编译、前端构建、配置审查和部署状态检查；修复后的完整多人游玩、语音切换、容器重启及灾备恢复仍待验收。核心单实例部署，不应未经跨实例路由/广播验证直接横向扩容。

发布状态（2026-10-10）：Core 006、AI Worker 002、Media Worker 002 均为 normal；管理端 004、玩家端 003 构建发布 SUCCESS。自定义域名 `/api/health` 返回 HTTP 200。

## 通信请求与延迟优化

客户端不再每 3 秒全量拉取 `/chat` 和 `/voice`。正常使用 WebSocket 通知：聊天变更只拉取聊天，语音状态直接使用推送 payload；每 60 秒补偿同步一次，页面后台不发起补偿同步，正在刷新时跳过定时触发。首次进入、重连、切场景仍立即刷新权限和范围。语音只有实际取得 grant 后每 10 秒保活，心跳/续期不再广播聊天变更。

后端将语音状态的成员、参与状态、租约及显示名称合并为一次带 LATERAL 的房间范围读取。HTTP SQL 非事务普通 SELECT 不再获得全局写锁；修改及锁定读取继续保留写锁，业务事务仍执行原有提交校验。没有使用跨请求鉴权缓存或取消封禁检查。

本轮完成编译和 Flutter Web 构建，继续遵守暂缓完整游玩测试的要求；尚未进行并发负载和语音端到端回归，不能声称达到具体响应延迟指标。

## Core 008 发布

2026-10-10 Core 008 已部署为 normal、100% 流量（BuildId 2608445100）。保留 CloudBase HTTP SQL，完成命令入口批量读取、事务内按表失效缓存、成员视图序号批量更新和 Server-Timing 诊断。`https://ruxi.fuyaten.online/api/health` 返回 200。玩家端 004、管理端 004 和 Worker 002 保持现有版本。

本轮针对数据库/指令的 HTTP SQL 18 项、原生路径 10 项检查通过；不代表完整生产游玩和 RTC 验收。

上线后独立测试房间单次诊断：role.select 首次提交 committed，客户端 1666ms，Server-Timing app=1608.3ms、db=1324.3ms、db_calls=11；同编号重放 committed，客户端 1733ms，app=349.4ms、db=333.9ms、db_calls=3。该数据仅为一次样本，客户端耗时还包含网络等待，不能外推为全部指令或并发性能保证。

## WS 指令发布修复（2026-10-10）

Core 009（BuildId 2608446686）上线后对照确认：member.ready 的 WS 回执约 0.71 秒、视图 0.79～1.16 秒；Core 008 同房间视图约 6.2 秒。Core 009 使用提交后即时广播，outbox 保留补发；命令数据库缓存和冗余读取继续优化。

玩家端 006（BuildId 2608440643）已发布 SUCCESS：正常游戏指令 room.command、交互报价 interaction.quote 均通过 WS；收到回执后等待推送水位，正常情况不再 POST commands 或 GET snapshot。命令断线恢复保留原编号，GET commands 仅作不确定结果查询。后端交互报价由 Core 010 提供，最终部署状态以下方记录为准。

最终发布：Core 010（BuildId 2608440642，RunId multi_tenant_1xFS4C9i1DrfwF）已 normal、100% 流量；玩家端 006 SUCCESS。玩家独立域名和 ruxi.fuyaten.online 返回的 main.dart.js SHA-256 均与本地本次构建一致。数据库保持 CloudBase HTTP SQL，无新增直连资源或套餐升级。

Core 010 上线后的独立房间复核：member.ready 回执 533/1015ms（6 次 DB），视图 667/1211ms；media.complete 回执 1456/1041ms（8 次 DB）；action.submit 回执 1435ms、视图 1645ms（8 次 DB）；room.start 回执 1925ms、视图 2222ms（11 次 DB）。重复编号的回执序号保持一致。复核首次遇到一次 SERVICE_UNAVAILABLE（CloudSQL 异常），重连后再次检查成功；错误原因尚未分解，不据此宣称无故障或所有请求均低于 1 秒。完整 RTC、并发负载和尾延迟验收仍未执行。
