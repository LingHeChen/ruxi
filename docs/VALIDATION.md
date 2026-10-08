# C1 开发版验收记录

验收日期：2026-10-08。范围为冻结三人样片《末班车的第七位乘客》的可运行开发实现；不是生产上线认证。

## 自动化结果

| 检查 | 结果 |
| --- | --- |
| Elixir `mix test` | 36 项通过 |
| Elixir `mix compile --warnings-as-errors` | 通过 |
| Python `uv run pytest` | 22 项通过 |
| 玩家 Flutter analyze / test | 无分析问题，7 项通过 |
| 制作台 Flutter analyze / test | 无分析问题，3 项通过 |
| 玩家与制作台 Flutter Web 构建 | 通过 |
| Android debug APK 构建 | 媒体校时版本通过；注销 UI 尚未重建 |
| iOS Simulator 构建 | 媒体校时版本通过；注销 UI 尚未重建 |
| Docker Compose 配置校验 | 通过；未运行容器 |

合计 68 项测试。新增覆盖账号注销及独立台账恢复、AST 可达性和错误图、隔离预览、保留清理、Worker 身份与失败释放、模型适配器异常回退、缓存到期、公共时间锚和低 RTT 校时。这些测试不能代替复合验收项全部通过。

## 真实协议联调

`node scripts/smoke.mjs` 已通过：三个独立游客经真实 Phoenix V2 WebSocket 建房、入房、同步、心跳及断线重连；跨角色媒体和错误私有 topic 被拒绝；线索、道具交付、重复命令、提示、中场和私有投票完成闭环。等待真实 45 秒决策截止后得到 E1，全员确认结局后读取持久化快照。

`node scripts/smoke_creator.mjs` 已通过：受控 CLI 登录、剧目和版本读取、草稿创建、AST 验证、隔离多角色预览、私有调查、道具交付、提示、E1、预览幂等及修改版本后旧预览失效。预览不创建真实游戏房间，也不发布内容。

签名视频 Range 请求返回 206 和正确字节段，字幕可读取，伪造媒体地址被拒绝。视频为本项目生成的八段原创开发动效，来源和哈希记录在媒体 manifest 中。

`services/worker/.venv/bin/python scripts/check_live_contracts.py` 校验本轮联调产生的 **3 份快照、96 条事件**，全部符合 JSON Schema。样本位于被忽略的 `.local/smoke-views.json`，仅包含合成玩家视图。

## 可查看产物

- 玩家 Web：`http://localhost:8080`
- 制作台 Web：`http://localhost:8081`
- Android：`apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`
- iOS 模拟器：`apps/mobile/build/ios/iphonesimulator/Runner.app`

## 验收限制

当前环境没有可用的应用内浏览器实例，因此未完成实际浏览器交互及截图验收。Widget 布局测试不能代替浏览器视觉验收。

未安装到实体手机测试；模拟器构建成功不能证明真机播放、弱网、后台切换或性能符合上线要求。Docker daemon 不可用，未验证容器运行。未进行 100 房间压测、备份恢复演练、完整无障碍审计或最终影视素材验收。

生产媒体链路、完整真实模型评估及云端持久台账等未完成范围见 [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)。启动方式和开发配置见 [README](../README.md)。

## CloudBase 及生产模式演练

目标环境的迁移 `20261008120500` 已成功应用，独立 `ruxi` schema 中有 25 张表，匿名和认证前端角色无 schema 使用权限。其他应用的迁移及数据保留。

本地生产 OTP release 构建成功，以生产 runtime 配置启动后 `/health` 返回 200，随后停止演练进程。这不能代替云托管容器构建及云数据库连接验收。

两次真实 DeepSeek 合成提示返回合法非模板结果；关闭 thinking 的一次耗时约 2.27 秒。完整模型质量与剧情泄露评估仍待执行。
