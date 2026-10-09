入戏场景语音增量设计 1.0
2026-10-09

阅读顺序
1. index.html：离线阅读四份正文与官方来源。
2. docs/V1_Scene_Voice.docx：产品规则、玩家与作者入口、UI、手机和宽屏示意。
3. docs/V2_Scene_Voice.docx：Flutter/Elixir 分工、凭证、频道、撤权与世界提交、恢复。
4. docs/V3_Scene_Voice.docx：数据、索引、HTTP/WS、管理和举报、DSL 增量。
5. docs/V4_Scene_Voice.docx：验收、成本、监控、部署与回滚。
6. prototype/voice.html：本地交互示例，直接用现代浏览器打开，不接RTC，不申请麦克风。

开发附件
contracts/openapi.json：OpenAPI 3.1，外部引用同目录 voice.schema.json。
contracts/voice.schema.json：请求、回执、投影、凭证、管理与举报结构。
contracts/policy.schema.json：DSL 增量形状，不替代全量发布格式。
examples：协议样例、作者配置、集中安全参数；50元日预算仅为可修改部署示例。
figures：Mermaid 架构与时序源文件、关键UI截图。
source：可维护正文Markdown及生成源JSON，与本版Word语义相同。
verification：14项能力追踪、18项待执行集成验收、附件检查结果与实际修复记录。
sources.json：官方来源和查阅日期，第三方服务行为以上线锁定版本联调为准。

适用与覆盖
配合C3三份文档使用；仅真人语音作用域固定为scene，不改变既有文字频道。
保留单人本和多人本。账号、地图、AP、密码、骰子与AI规则沿用既有设计。
本包没有修改实际项目，也没有开通云服务。音频回收传播、平台权限和SDK音质待真机验收。
HTML不覆盖整套应用，也不证明原生性能、安全隔离或真实录音行为。

检查复现
在安装jsonschema的Python环境执行 python verification/validate_contracts.py。
browser_check.cjs 记录本次浏览器检查脚本，使用Playwright；重跑需将Chromium路径和工作目录替换为本机路径。
契约示例中的Token/AppID都是不可用的演示值，不可当作生产凭证。

文档权威
V1管产品行为，V2管执行顺序，V3与contracts管字段，V4管验收。图片与HTML说明呈现，不能覆盖权限规则。
