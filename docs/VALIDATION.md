# C1 工程验收记录

日期：2026-10-08。范围为原设计中的玩家、制作、模型、素材和运营功能，以及用户补充的软件入口、账号和后台界面要求。记录本地实际检查；设备和云端检查不以构建成功代替。

## 自动化

|检查|结果|
|---|---|
|Core 编译与 PostgreSQL 测试|warnings-as-errors 通过；70 项通过|
|Python Worker|29 项通过|
|玩家端 Flutter|分析无问题；22 项通过|
|制作台 Flutter|分析无问题；11 项通过|
|Node 协议归并|3 项通过|
|两端 Web|构建通过|
|Android debug APK / iOS Simulator|构建通过，已实际启动 iOS 首页|
|生产 OTP release|构建及 /health 200 通过|
|Docker Compose|配置通过；daemon 不可用，未实际构建运行容器|

合计 135 项（以最后运行结果为准）。覆盖三结局、权限、回执、投影、冻结选民、租约、不可变素材、字幕、人工编辑建议、公开复盘、离线房间释放、有界诊断、聊天治理及擦除。

## GitHub 独立环境验证

2026-10-08，[GitHub Actions 验证](https://github.com/LingHeChen/ruxi/actions/runs/37797937142)对源码提交 `689fc8d` 全部通过：Core 数据库迁移、严格编译与测试，Worker 哈希锁定安装、测试与协议生成一致性，两套 Flutter 静态分析、测试与 Web 构建，Node 协议测试，以及 Core/Worker 生产 Docker 镜像构建。源码已以 MIT 许可证公开于 [LingHeChen/ruxi](https://github.com/LingHeChen/ruxi)。镜像构建成功不代表容器运行、CloudBase 部署或正式运营验收完成。

补做后的最终源码提交 `b0c1e1a` 的 [GitHub Actions 验证](https://github.com/LingHeChen/ruxi/actions/runs/37804280391)六个任务全部成功，涵盖上述 135 项测试、两套 Web 构建、契约再生成和两个生产镜像构建；摘要保存于 `docs/evidence/portal-ci.json`。新迁移 013 也通过独立空数据库的生产 release 演练。正式产品验收仍未认定通过。

## 软件入口与后台补做

用户指出上一版直接开房、缺少登录注册/个人空间/搜索分类，以及制作台没有正式后台形态；此前“全部功能完成”的结论撤回。本次加入四个玩家入口与账号闭环，以及后台导航、工作概览、剧目表、展示设置、素材库、用户目录和角色分配。

390×844、1280×1000 玩家界面及 390×844、1440×1100 后台界面通过 Flutter Widget 导航与布局检查，实际渲染图在 `docs/screenshots/*-widget.png`。这些图片使用合成测试数据；不属于浏览器截图，也不代替用户视觉验收。新增账号测试覆盖盐化密码摘要、重复注册回执、游客升级、资料和收藏隔离、普通玩家/管理员权限、密码修改/恢复码重置和注销清理。`smoke_accounts.mjs` 实际 HTTP 的 16 项账号与目录检查通过，凭证没有写入报告。

## 实际 HTTP / WebSocket / Worker

- `smoke.mjs`：E1、E2、E3 均经过真实三游客和 45 秒决策截止。签名 MP4 Range 206、授权字幕、伪造 capability 和私人媒体拒绝、设备重连、重复分享、道具及提示闭环通过。
- `smoke_creator.mjs`：CLI 管理员登录、版本草稿、验证、三视角隔离预览、幂等和 revision 失效通过。
- `smoke_production.mjs`：真实原文件上传、Worker 转码、首帧、不可变字幕修订、AI 惰性建议与人工应用、验证/审核/冻结发布、三玩家授权播放通过。模型建议来自真实供应商。
- `smoke_operations.mjs`：诊断接受/拒绝与去重、隐私字段拒绝、注销后凭证撤销、失败预算与 Retry-After 通过。
- `smoke_races.mjs`：同时选唯一角色、并发同 ID 开局、接受与取消交付竞争、并发重复接受、归属版本仅增加一次及私有隔离通过。
- `check_live_contracts.py`：最新 E1 的 3 份合成快照和 96 条事件符合 JSON Schema。
- 真实 DeepSeek 六项合成提示均结构合规、非模板、未出现未授权 canary，耗时 1.236–2.094 秒；不代替人工剧情质量审阅。

## 故障与恢复

`fault_drill.mjs` 在独立数据库的提交响应期间 SIGKILL，重启后重放三个视角、原命令回执精确相同、数据库只有一条命令、私有线索隔离均通过。

`restore_drill.mjs` 在独立 PostgreSQL 17 数据库恢复约 618 MiB 备份，然后执行离线恢复控制与最新独立擦除台账。最新演练 120.752 秒，恢复时备份年龄 77.314 秒；已擦除账号仍被擦除，旧会话全部撤销，owner/租约与恢复 epoch 已重置。该单次本地测量不代表云端 RPO/RTO SLA、异地备份或 PITR 通过。

## 持续负载

完整复测：100 房间、300 WS，目标 100 有效命令/秒，25 分钟共 150,000 次尝试和成功，零错误。意图到回执及本地投影应用 p50 94 ms、p95 492 ms、p99 763 ms。本机 Apple M4 / 10 逻辑核心 / 32 GiB；期间同机进行了备份恢复和编译，并非独占负载机器。

修复后的额外 5 分钟专项：100 房间、300 连接，30 名不同成员共 60 次重连；29,992 次有效命令全部成功，零错误。p50 65 ms、p95 126 ms、p99 129 ms。前一次脚本退出等待发现目标变量覆盖请求计数，已修复并加入计数归属回归测试；没有完成的轮次不记通过。首轮发生单次重连超时，次轮因脚本未缓冲乱序中断；后续又发现历史挂起房间持续定时查询，均没有计为通过。已修复脚本的持久补发、重连前排空请求，以及挂起房间释放进程与租约，由 Oban 处理到期。额外重连专项首次因恢复扫描重新唤醒历史挂起房间失败；已限制只扫描运行/暂停房间、每 5 秒扫描一次，并批量更新广播回执，失败轮次没有计为通过。

负载实际为 briefing 阶段聊天，循环本机 HTTP/WS，不包含 TLS/WAN、视频分发或手机 UI。测量意图到回执及本地协议投影应用，不能当成正式 QA29 的提交到手机显示延迟、混合业务比例或 WSS 证明。

## 产物及限制

玩家 `http://localhost:8080`，制作台 `http://localhost:8081`；APK 位于 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`，模拟器应用位于 `apps/mobile/build/ios/iphonesimulator/Runner.app`。

补做后的 iOS 27 iPhone 18 Pro 模拟器实际首页已启动并留图 `docs/screenshots/ios-portal-home.png`；`ios-home.png` 保留为之前版本的历史证据。未安装实体手机测试；应用内浏览器实例不可用，未完成真实浏览器视觉与交互验收。G0/G1 未测子项仍按 [QA_TRACE.md](QA_TRACE.md) 记录。

CloudBase 独立 ruxi schema 初始 25 表已验证；本地迁移推进至 013，增量尚未应用云端，容器、持久卷、TLS/WSS、连接权限和告警待部署验收。按用户要求先开发后部署。

## 2026-10-09：房间重连与 Web 路由修复

用户实测发现加入房间后持续显示重连。使用真实 Flutter `RoomClient` 连接本地 Core 复现：`clock_ping` 多传 `client_sent_at`，后端严格校验仅接受 `nonce`，返回 `INVALID_ARGUMENT`；客户端将错误响应当作正常校时结果，解析空时间抛错并重连。已对齐请求、正确处理普通 WS 调用错误，并保留命令拒绝回执语义。真实客户端入房、校时、开局拒绝、连接保持及再次入房通过；此测试加入 Core CI，独立 Flutter 单元测试任务没有后端时明确跳过。

玩家端与制作台接入 `go_router` 和路径 URL：玩家首页、发现、个人空间、房间记录、剧目详情及具体房间；后台概览、剧目、素材、举报、用户及具体内容版本。搜索词、题材、人数和排序写入 URL，编辑器工作区写入查询参数。URL 重建测试验证个人空间、筛选、房间、后台页面和指定版本恢复。保留标签页身份边界，直接房间地址仍需原身份及成员权限。

本地预览服务器按导航路径回退 `index.html`，处理 `/assets` 页面与 Flutter 同名目录冲突；不存在的静态文件仍返回 404。两端分析无问题，玩家 25 项与制作台 13 项单元/组件测试通过；另有真实 Flutter/Core 联调 1 项与静态 HTTP 回退 1 项，两套 Web 构建通过。本轮没有将 Widget 路由测试或 HTTP 检查称为真实 Chrome 刷新实测。CloudBase 上线时仍需配置同等导航重写规则。

源码提交 `b1d1f1d` 的 [GitHub Actions 独立验证](https://github.com/LingHeChen/ruxi/actions/runs/37808352347)六个任务全部通过，包含新增真实 Flutter/Core 联调、路径回退测试、两端分析与 Web 构建，以及原后端、Worker、协议和镜像构建检查。
