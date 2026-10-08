# AI 供应商适配

玩家提示默认不依赖外部模型即可运行。用户选定 DeepSeek 为预期供应商，具体服务封装在 `services/worker/adapters.py`，核心服务与 Flutter 客户端不依赖供应商 SDK。

## DeepSeek

在 Worker 进程的环境中设置以下配置，再重启 Worker。模型名称可替换，不写入游戏图或客户端。

```sh
export MODEL_PROVIDER=deepseek
export MODEL_BASE_URL=https://api.deepseek.com
export MODEL_NAME=deepseek-flash
export DEEPSEEK_API_KEY='你的密钥'
uv run uvicorn worker:app --host 127.0.0.1 --port 8000
```

密钥仅属于 Worker，不能放到 Flutter 编译参数、制作台浏览器、本地截图或版本库。也可将 `services/worker/.env.example` 复制为同目录的 `.env`；Worker 自动读取，进程环境变量优先。`.env` 已被 Git 忽略，本地密钥文件权限应为 600。`MODEL_BASE_URL` 必须为 HTTPS 基础地址，不包含用户信息、查询参数或片段。请求发送至该地址下的 `/chat/completions`。

其他兼容供应商设置 `MODEL_PROVIDER=openai_compatible`，并设置 `MODEL_BASE_URL`、`MODEL_NAME` 和 `MODEL_API_KEY`。供应商默认是 DeepSeek，缺少密钥时自动使用模板。显式关闭外部模型使用 `MODEL_PROVIDER=template`。

## 游戏边界与回退

模型输入仅包括当前角色、当前已知/公共线索、已授权线索正文、提示层级和固定兜底文字。适配器不发送整个剧本、其他角色私有状态、未来片段或身份凭证。模型结果只允许提示文字和已知线索引用；不接受状态补丁、工具调用或发布指令。

每项任务只尝试一次供应商请求，超时为 5 秒。缺少密钥、供应商错误、截断、错误结构或越权线索引用均回退到固定提示；核心服务另外保留 8 秒兜底及阶段/知识基线校验。供应商适配不会改变游戏结算事实。

这些检查限制输入和输出格式，但不能证明自然语言永远不会猜测剧情。密钥已配置在忽略的本地文件中；模型列表查询及两次真实合成提示均成功，结果为合法非模板输出。关闭 thinking 的一次请求耗时约 2.27 秒。真实调用可能产生费用；已执行六项真实 DeepSeek 合成案例（空知识、已知线索、二级提示、注入、结局诱导、标记文本），全部输出结构合规且未回退，耗时 1.236–2.094 秒。该结果不等于人工剧情质量与全部注入评估通过。

编辑辅助经 `editor_adapter.py` 使用同一供应商配置，20 秒超时，只发送选定文本和编辑指令。结果必须是限定建议字段，Core 绑定原版本、目标和摘要；用户确认应用后才更新草稿，旧审核立即失效。真实制作流程已验证模型建议与人工应用。

## Worker 凭证

开发凭证允许 `player_hint`、`editor_ai` 和 `media_transcode`。生产应将 AI 与媒体分开，分别设置 `SUPPORTED_KINDS` 和对应任务权限，媒体进程不接收供应商密钥。生产核心服务可通过 `WORKER_CREDENTIALS_JSON` 配置独立的 `{worker_id, token, allowed_kinds}` 列表；Worker 的 `WORKER_ID`、`WORKER_TOKEN` 必须与之匹配。更改请求中的 worker_id 无法取得其他身份的租约；完成、失败和心跳也校验原租约所属身份。

`GET http://localhost:8000/health` 显示供应商模式及是否配置密钥，不返回密钥。运行配置成功不等于真实供应商请求已通过。
