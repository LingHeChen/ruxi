入戏 C3 增量设计 2026-10-09

阅读顺序
1 docs/Ruxi_C3_Gameplay.docx：先看玩家如何探索、对抗与改变世界。
2 docs/Ruxi_C3_Studio_UI.docx：由玩法倒推世界、场景、互动与状态预览。
3 docs/Ruxi_C3_Technical_Acceptance.docx：数据、接口、随机恢复、迁移、验收与C2覆盖表。
也可以在解压后打开 index.html 连续阅读三份正文。

本期范围
新增互动形式只有 password 密码输入和 check 骰子判定，既有选项与自由行动继续保留。战斗明确延期。动态通路、地图发现、个人知识、阵营目标、非战斗对抗、NPC与离散环境事件纳入本期规则扩展。复杂物理、重量运输、永久成长、战役与时间循环为后续候选，未自动纳入本期开发。
本包是 C2 的增量覆盖，不是整套替换，不会改变已有项目源码。实际版本号需结合已开发工程校准；新增规范建议内容4、协议3，Phoenix传输版本不变。覆盖关系见技术文档第12节。

配套界面
prototypes/studio.html：选择地点进入场景；选择通路打开检查器；更改方向、费用、到达封路规则；应用、撤销、保存；切换作者/角色视角及初始/封路/修复快照。
prototypes/interactions.html：密码输入与骰子确认、排队、取消、结果、断线与减动效。顶部为测试控制，不属于玩家UI；“模拟步结算”替代真实多人提交。密码测试值0427；骰子固定37，仅验证呈现。角色过滤在本地模拟，不是安全实现。
HTML不连接网络服务，无外部依赖。图示为实际HTML截图。工作台显示的是关键视图参考，其余页面行为按正文实现；没有宣称完整应用、正式游戏美术或全部编辑表单已交付。

契约与样例
contracts/extension.schema.json：本期增量profile形状，不是完整发布DSL。
contracts/commands.schema.json：两类interaction.submit命令形状。
examples/extension.json：通路、密码和判定的有限样例；其他场景、角色与事件由正文规定并与原DSL合并。
examples/author_only_secrets.json：仅作者测试夹具，禁止作为玩家资源发布。
examples/wire.json：样例命令、报价与投影结果；包含输入夹具，不是日志模板。
figures/world_model.mmd、resolution.mmd：Mermaid世界投影与结算关系。
verification/coverage.csv：能力、范围、页面、文档与验收映射。

验证
Python环境需安装jsonschema，从任意目录运行 python verification/validate.py。
验证结果见verification目录。纯函数和浏览器模拟不等于真实Elixir/数据库/WS、React Flow或Flutter联调；C301–C320完整产品验收仍需实施后运行。
正式上线前优先验证随机日志崩溃恢复、逐受众信息隔离、重连幂等、多人最后一次密码竞争、失败分支可结束与旧房兼容。

浏览器检查复现：安装Playwright，从包含c3_package目录的父目录运行 node c3_package/verification/browser_check.cjs。可用CHROMIUM_EXECUTABLE指定Chromium路径；未指定时使用Playwright默认浏览器。
