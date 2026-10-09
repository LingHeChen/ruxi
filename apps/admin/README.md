# 入戏管理后台

React + TypeScript + Vite + Ant Design + React Flow。Node.js 24。

```sh
npm ci
npm run dev
```

后台默认 http://localhost:8081，Core 默认 http://localhost:4000。管理员账号权限由 Core 管理；支持账号密码与一次性登录码，会话按标签页保存。

```sh
npm run typecheck
npm test
npm run build
python3 ../../scripts/serve_web.py --directory dist --port 8081
```

部署 `dist`，设置构建变量 `VITE_API_BASE`，配置 SPA 回退和 Core CORS。所有 `VITE_` 变量对浏览器公开，禁止写入 DeepSeek 或云服务密钥。

后台覆盖工作概览、剧目与版本目录、内容工作室、素材库、举报审核及角色权限管理。内容工作室的完整表单遵循 `contracts/content/graph.schema.json`；画布投影角色、行动、线索条件、阶段与结局，节点属性编辑后自动更新关系；布局仅在浏览器保存，不改变剧情内容指纹。发布前由服务器校验素材、引用和可达性，审核随内容修订失效。

保留 `apps/creator` 作为迁移前 Flutter 参考；当前后台使用本目录。真实浏览器视觉验收与 CloudBase 部署仍待完成。
