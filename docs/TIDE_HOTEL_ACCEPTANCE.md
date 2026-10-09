# 《潮汐旅馆：第九声钟响》开发验证

本地玩家入口：[打开故事](http://localhost:8080/stories/c2fed93e-289c-4435-82b3-3f39fbd46529)。本地制作台：[编辑故事](http://localhost:8081/stories/c2fed93e-289c-4435-82b3-3f39fbd46529/world)。仅发布到本地开发库，未部署云端。

内容、作者说明和提示词位于 `content/c3/tide_hotel/`；26张采用图片位于 `apps/mobile/assets/stories/tide_hotel/`。32项预设交互、密码/判定输入及结果、4位NPC、全部8场景、23条线索、5结局都有图片绑定。修订前图片保留为旧版本，不覆盖旧发布素材。

## 验证与实际边界

- Core 全套108项测试通过，其中6项检查本故事五个结局、NPC可见性、未知道路与秘密隔离、密码耗尽后主线、修复成功/失败的替代路线、图片发布哈希门禁。
- Flutter全套原40项加3项新NPC图文布局测试；两个明确需实时开启的旧测试仍跳过。390/768/1440逻辑宽度检查NPC入口、图文面板及交谈选项。截图为真实Flutter组件、引擎生成投影夹具，不等价于完整浏览器真人试玩。
- 真实HTTP测试从游客身份、选角、开局、每次叙事确认、密码报价与提交一路执行，分别到达全部五个结局。正常终局路线48次行动、9回合；耗尽密码后仍完整通关，54次行动、10回合。完整结果位于忽略目录 `.local/tide_hotel/http-evidence.json`。
- Web发布构建可读取全部采用图片，下载内容与冻结SHA-256逐一核对。图片发布清单位于 `services/core/priv/c3/bundled_art.json`，没有直接开放任意图片URL发布。
- NPC采用预设对话与条件回访，不是AI自由聊天；没有配音和随机NPC游走。玩家时长30～60分钟是内容与阅读节奏估计，仍待真人计时校准。

## 重跑

```sh
python3 scripts/build_tide_hotel.py
cd services/core
mix test
cd ../../apps/mobile
flutter test
flutter build web --release
cd ../..
node scripts/publish_tide_hotel.mjs
```

制作台和玩家端都需要运行最新构建。旧房间按旧发布继续运行，体验修改后的图片应创建新房间。
