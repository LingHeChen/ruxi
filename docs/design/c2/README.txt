入戏 C2 设计包 2026-10-09

建议先读 D02 游戏系统、D03 交互界面、D07 工作台、D08 DSL。
index.html 内含十二篇正文，解压后直接用浏览器打开。docs 为可编辑 DOCX，保留旧六篇文件名是为了保持版本身份，正文均已统一为 C2。

本次交付
十二篇设计文档及同源文本；玩家端、工作台、组件 HTML 与四张实际浏览器截图；Flutter 和 React Flow 技术实验源码；五份 JSON Schema；OpenAPI；数据字典与约束参考；餐厅 JSON 样例、布局、三份无效样例、AI评估样例及 golden trace；三份 Mermaid；验证脚本、结果与能力追踪表。

原型运行
打开 prototypes/player.html 或 studio.html，不需要安装依赖，不连接外部服务。
玩家端模拟三席中的本人，队友通过明确标记按钮模拟。确认动作后按“模拟队友确认并结算”；每轮3点，最多3步，四轮末兜底结束。
预设路线：询问服务员 → 地图去走廊 → 输入门禁 → 新轮去后厨 → 关闭电源。
自由路线：去走廊 → 取灭火器 → 结束本轮 → 其他行动输入“用灭火器破门”并确认 → 去后厨 → 关闭电源。费用不足须等待下一轮。
工作台可修改行动名称、成本与效果，撤销、保存到localStorage、切换事件关联、验证错误并导出JSON。生成候选、改编任务与队友均为明确标注的本地模拟。

验证运行
Python 3.12，安装 jsonschema（本轮版本见 verification/results.json）：
  python verification/validate.py
  python verification/reference_engine.py
参考引擎只覆盖本包餐厅用到的确定性行动、并行步顺序、个人知识和结局。概率、协同组、投票、真实数据库/WS/AI/媒体及原生性能仍按D11实现验收；参考脚本不是生产引擎。

框架实验
flutter_probe.dart：复制到 Flutter 项目 lib/main.dart，运行目标平台；验证拖动面板、布局变化、输入和提交计数，无真实视频插件。
react_flow_probe.tsx：放入已安装 React 与 @xyflow/react 的项目并导入默认组件。依赖需在目标项目锁定；两份框架实验均未编译运行。HTML只用于视觉和行为参考。

版本与范围
内容schema_version=3，应用protocol_version=2，Phoenix传输vsn=2.0.0。付费、公开匹配、语音、AI补位及独立单人产品模式是未决扩展。每轮3点、45s步时限是建议配置，需试玩校准。
正式实施前确定支持设备与最低系统、供应商和上线资源、保留政策、身份产品化方式及节奏参数。本包不是回旋加速公司的内部架构，也不声称现有应用已更新。
