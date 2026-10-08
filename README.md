# 入戏 Ruxi

根据 `Ruxi_Design_Documents_C1.zip` 实现的协作互动剧平台。Flutter Android/iOS 玩家端、Flutter Web 制作台、Phoenix Channels 权威房间服务、PostgreSQL 持久状态和 Python Worker。

已实现《末班车的第七位乘客》的三人玩法闭环。已补充八段原创程序化动效开发视频、字幕与同视角摘要，并接入授权播放器。制作端上传、转码、首帧、字幕、AI 建议和发布流程已接通，备份恢复与进程崩溃演练已通过。真机、浏览器和云端上线验收仍需执行，详见 [实现与验收状态](docs/IMPLEMENTATION_STATUS.md)。

核心设计与取舍见 [架构说明](docs/ARCHITECTURE.md)，制作和恢复流程见 [运行手册](docs/OPERATIONS.md)。

<details><summary>iOS 模拟器实际首页</summary>

<img src="docs/screenshots/ios-home.png" width="280" alt="入戏 iOS 首页：原创三人互动故事">

</details>

## 目录

- `apps/mobile`：玩家端和 Web 开发预览；私有视图、顺序同步、命令查证、手机 SQLite 缓存、Keychain/Keystore 凭证。
- `apps/creator`：制作后台；独立管理员登录、版本草稿、校验、审核、发布门槛。
- `services/core`：Elixir/Phoenix/Ecto；事务命令、幂等回执、成员投影、outbox、计时和媒体授权。
- `services/worker`：FastAPI/HTTPX 任务领取、租约心跳与完成重试；模板、DeepSeek 和兼容服务适配器。
- `contracts`：OpenAPI 3.1 JSON、WS/Worker JSON Schema 和正反例 fixtures。
- `content/demo`：冻结三人样片；白名单 AST 引擎及内容格式支持 2–4 席位，并执行有上限的可达性检查。
- `docs/design`：原压缩包中的六份 DOCX、提取正文、图稿和 HTML 参考。

## 启动

需要 Flutter 3.47/Dart 3.13、Elixir 1.19/OTP 28、PostgreSQL 17、Python 3.12 和 uv。依赖通过 lockfile 固定。

启动本地 PostgreSQL（或 Docker）：

```sh
docker compose -f infra/compose.yaml up -d postgres
export DATABASE_URL='postgres://ruxi:local-development@localhost:55432/ruxi_dev'
cd services/core
mix setup
ulimit -n 4096
PHX_SERVER=true mix run --no-halt
```

亦可在项目根目录 `docker compose -f infra/compose.yaml up --build` 启动数据库、core 和 worker。Compose 为开发配置；本次环境 Docker daemon 未运行，因此未实测容器构建。

本次已运行的本机 PostgreSQL 使用 `/tmp/ruxi-pg`、55432 端口和当前系统用户，默认 `DATABASE_URL=postgres://localhost:55432/ruxi_dev`。此临时数据库仅供开发。

另开终端启动玩家端：

```sh
cd apps/mobile
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=API_BASE=http://localhost:4000
```

也可构建并用项目预览服务器访问：

```sh
cd apps/mobile
flutter build web
cd ../..
python3 scripts/serve_web.py --port 8080
```

手机连接时将 API_BASE 设为设备能访问的 HTTPS 地址。Android 模拟器访问宿主机使用 `10.0.2.2`；真机使用局域网地址。发布版需要 TLS，不会全局放开 iOS ATS 或 Android 明文流量。

Web 试玩身份按标签页保存：在地址栏分别打开三个新标签页即可作为三个玩家，刷新保留该标签页的身份。不要使用浏览器「复制标签页」，它可能复制 sessionStorage 身份；请新建标签页后输入网址。手机端仍使用设备安全存储。房主建房后复制八位邀请码；全员选角、准备，然后由房主开局。更新前已创建的房间需要使用原游客恢复码恢复，或直接在新版本重新建房。

完整路线：全员确认公共开场 → 各自确认角色片段 → 调查员调查并公开 C1 → 乘客调查得到 C2 并交付 → 乘务员接受 C2、解锁控制柜并公开 C3 → 全员结束探索 → 确认中场 → 两票「公开异常」 → 45 秒截止进入 E1。未公开 C3 时，两票等待得 E2；离开、平票或全弃权得 E3。

## 制作台

部署 CLI 为指定受控账号签发一次性后台登录码（有效 5 分钟）：

```sh
cd services/core
mix run --no-start priv/repo/admin_code.exs 33333333-3333-4333-8333-333333333333 editor reviewer publisher
cd ../../apps/creator
flutter run -d chrome --web-port 8081
```

输入 CLI 返回的登录码。先基于样片创建草稿，再编辑和验证。修改后旧审核失效；已发布版本不可编辑。可上传自有授权视频，自动转码并预览首帧，附加字幕后绑定草稿；AI 建议需人工确认。样片媒体已就绪，创建草稿后可验证、审核并发布；媒体缺失/摘要不匹配时拒绝发布。初始免费样片是明确的开发 fixture，不能据此宣称已完成最终素材制作。

可选运行 Python Worker：

```sh
cd services/worker
uv sync --extra test
uv run uvicorn worker:app --host 127.0.0.1 --port 8000
```

不启动 Worker 时，core 仍会在 8 秒后提供固定提示。Worker 无数据库连接，通过绑定身份和任务种类的凭证领取任务。AI 使用供应商适配层，支持固定模板、DeepSeek 和 OpenAI 兼容接口；配置方式见 [AI 配置](docs/AI_CONFIGURATION.md)。未配置密钥时使用模板。六项真实合成提示与真实编辑建议流程通过，人工剧情质量仍需验收。

## 验证

隔离测试库已创建后，可运行 `scripts/verify.sh` 完成 Core、Worker、协议归并及两端分析/测试/Web 构建。

```sh
cd services/core
MIX_ENV=test mix ecto.create
MIX_ENV=test mix run --no-start priv/repo/init_schema.exs
MIX_ENV=test mix ecto.migrate
mix test
cd ../../apps/mobile
flutter analyze
flutter test
cd ../creator
flutter analyze
flutter test
cd ../../services/worker
uv run pytest
cd ../..
node scripts/smoke.mjs
```

`smoke.mjs` 创建三个真实游客并连接 Phoenix V2 帧，验证隐私、重复命令、道具、提示、中场、投票及 E1 持久化。它使用真实 45 秒决策截止，不修改服务器时钟或提供 HTTP 玩法后门。

视频来源记录和 SHA-256 位于 `content/demo/media/manifest.json`，均为本项目原创程序化画面、叙事文字及合成音。重建：`python3 scripts/generate_demo_media.py`，需要 FFmpeg 和中文字体；可设置 `RUXI_VIDEO_FONT` 指向本机字体。视频源不依赖外部影视、图像或音乐。媒体经授权签名网关分发；上传对象由不可变本地适配器管理，生产必须挂载持久 OBJECT_ROOT，后续可替换对象存储/CDN。

生成/检查机器契约：`python3 scripts/generate_contracts.py`；Python 契约测试验证正反例、Schema 自身及五条 golden fixtures。运行 smoke 后可执行 `services/worker/.venv/bin/python scripts/check_live_contracts.py` 校验实际快照和事件。完整验收记录见 [VALIDATION.md](docs/VALIDATION.md)。

部署时应设置独立 `SECRET_KEY_BASE`、`WORKER_TOKEN`、`CORE_INSTANCE` 和 `RECOVERY_EPOCH`；灾难恢复须从恢复控制面更换 epoch。当前为单 core 节点开发范围，不能直接启用多节点并宣称高可用。

## CloudBase 与许可

目标环境为 `tnt-like-d2gmmbwti62706aae`：Elixir 与 Python 部署到云托管，Flutter Web 部署到独立静态托管应用。云端及本地使用独立 `ruxi` schema，不在 `public` 下建业务表。部署记录及尚缺前置项见 [CloudBase 文档](docs/CLOUDBASE.md)。

项目使用 [MIT 许可](LICENSE)，依赖及工具遵循各自许可。源码仓库：[LingHeChen/ruxi](https://github.com/LingHeChen/ruxi)。应用的真机和云端发行验收独立于源码公开发布，未完成的项目见验收记录。
