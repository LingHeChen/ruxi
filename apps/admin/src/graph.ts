import Ajv2020 from "ajv/dist/2020";
import addFormats from "ajv-formats";
import schema from "../../../contracts/content/graph.schema.json";
import type { Json } from "./api";
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
export const validateGraph = ajv.compile(schema);
export const graphSchema = schema as Json;
export const labels: Record<string, string> = {
  title: "名称",
  description: "介绍",
  public_description: "公开介绍",
  text: "线索内容",
  shareable: "可公开分享",
  roles: "角色编号",
  role_definitions: "角色介绍",
  clues: "线索定义",
  actions: "行动",
  variables: "变量",
  decision: "投票与结局",
  timing: "阶段计时",
  assets: "片段与素材",
  hints: "固定提示",
  option_labels: "选项名称",
  label: "展示名称",
  id: "行动编号",
  role: "执行角色",
  phase: "所属阶段",
  requires: "触发条件",
  effects: "产生的结果",
  all: "全部满足",
  any: "任一满足",
  not: "不满足",
  public_clue: "已公开线索",
  knows_clue: "已知线索",
  owns_item: "持有道具",
  var: "变量编号",
  eq: "等于",
  grant_clue: "获得线索",
  grant_item: "获得道具",
  set_variable: "设置变量",
  visibility: "可见范围",
  value: "变量值",
  type: "变量类型",
  initial: "初始值",
  min: "最小值",
  max: "最大值",
  duration_ms: "时长（毫秒）",
  options: "选项编号",
  eligibility: "选项条件",
  default_option: "默认选项",
  tie_priority: "平票优先顺序",
  endings: "选项对应结局",
  exploration_ms: "探索时长（毫秒）",
  interlude_ms: "中场等待（毫秒）",
  ending_ms: "结局等待（毫秒）",
  media_id: "片段编号",
  asset_id: "素材编号",
  sha256: "内容指纹",
  summary: "文字摘要",
  source: "版权与来源",
  seat_count: "参与人数",
  demo_only: "演示内容",
  asset_status: "素材状态",
  exploration: "探索阶段",
  schema_version: "内容格式版本",
  story_id: "剧目编号",
  phases: "固定阶段",
  media: "片段编号列表",
  min_protocol_version: "协议版本",
};
export function resolveSchema(s: Json): Json {
  return s.$ref ? graphSchema.$defs[s.$ref.split("/").pop()] : s;
}
export function defaultValue(s: Json): any {
  s = resolveSchema(s);
  if (s.const !== undefined) return structuredClone(s.const);
  if (s.enum) return s.enum[0];
  if (s.oneOf) return defaultValue(s.oneOf[0]);
  if (s.type === "object")
    return Object.fromEntries(
      (s.required ?? []).map((key: string) => [
        key,
        defaultValue(
          s.properties?.[key] ?? s.additionalProperties ?? { type: "string" },
        ),
      ]),
    );
  if (s.type === "array")
    return Array.from({ length: s.minItems ?? 0 }, () => defaultValue(s.items));
  if (s.type === "boolean") return false;
  if (s.type === "integer") return s.minimum ?? 0;
  return "";
}
export function conditionRefs(condition: Json): string[] {
  if (!condition || typeof condition !== "object") return [];
  return Object.entries(condition).flatMap(([key, value]) =>
    ["public_clue", "knows_clue", "owns_item"].includes(key)
      ? [String(value)]
      : Array.isArray(value)
        ? value.flatMap(conditionRefs)
        : typeof value === "object"
          ? conditionRefs(value)
          : [],
  );
}
export function setGraphPath(
  graph: Json,
  path: (string | number)[],
  value: any,
): Json {
  const next = structuredClone(graph);
  let target = next;
  path.slice(0, -1).forEach((key) => {
    target[key] ??= {};
    target = target[key];
  });
  target[path[path.length - 1]] = value;
  return next;
}
export function buildRelations(graph: Json) {
  const nodes: Json[] = [];
  const edges: Json[] = [];
  const node = (
    id: string,
    title: string,
    kind: string,
    path: (string | number)[],
    column: number,
    row: number,
    detail: string,
  ) =>
    nodes.push({
      id,
      type: "story",
      position: { x: column * 300, y: row * 155 },
      data: { title, kind, path, detail },
    });
  const edge = (source: string, target: string, label: string, kind: string) =>
    edges.push({
      id: `${source}:${target}:${kind}:${edges.length}`,
      source,
      target,
      label,
      type: "smoothstep",
      data: { kind },
      style: { stroke: kind === "condition" ? "#a16a20" : "#708f84" },
      deletable: false,
    });
  (graph.roles ?? []).forEach((role: string, i: number) =>
    node(
      "role:" + role,
      graph.role_definitions?.[role]?.title ??
        (
          {
            investigator: "调查员",
            passenger: "乘客",
            conductor: "乘务员",
          } as Json
        )[role] ??
        role,
      "角色",
      ["role_definitions", role],
      0,
      i,
      graph.role_definitions?.[role]?.public_description ?? role,
    ),
  );
  (graph.actions ?? []).forEach((action: Json, i: number) => {
    node(
      "action:" + action.id,
      action.label ??
        (
          {
            inspect_monitor: "检查监控",
            inspect_phone: "检查手机",
            open_cabinet: "打开控制柜",
          } as Json
        )[action.id] ??
        action.id,
      "行动",
      ["actions", i],
      1,
      i,
      `探索阶段 · ${action.effects?.length ?? 0} 个结果`,
    );
    edge("role:" + action.role, "action:" + action.id, "执行", "role");
  });
  const ids = new Set<string>(Object.keys(graph.clues ?? {}));
  (graph.actions ?? []).forEach((a: Json) => {
    (a.effects ?? []).forEach((e: Json) => {
      if (e.grant_clue || e.grant_item) ids.add(e.grant_clue ?? e.grant_item);
    });
    conditionRefs(a.requires).forEach((id) => ids.add(id));
  });
  [...ids].forEach((id, i) =>
    node(
      "clue:" + id,
      graph.clues?.[id]?.title ?? id,
      "线索",
      ["clues", id],
      2,
      i,
      graph.clues?.[id]?.text ?? "尚未填写线索正文",
    ),
  );
  (graph.actions ?? []).forEach((action: Json) => {
    (action.effects ?? []).forEach((e: Json) => {
      if (e.grant_clue || e.grant_item)
        edge(
          "action:" + action.id,
          "clue:" + (e.grant_clue ?? e.grant_item),
          `${e.grant_item ? "获得道具" : "获得线索"} · ${e.visibility === "public" ? "公开" : "私有"}`,
          "effect",
        );
    });
    conditionRefs(action.requires).forEach((id) =>
      edge("clue:" + id, "action:" + action.id, "触发条件", "condition"),
    );
  });
  return { nodes, edges };
}
export function buildPhases(graph: Json) {
  const definitions = [
    ["briefing", "共同开场", "全员确认开场与角色片段"],
    ["exploration", "探索", `${(graph.timing?.exploration_ms ?? 0) / 1000} 秒`],
    ["interlude", "中场", `${(graph.timing?.interlude_ms ?? 0) / 1000} 秒等待`],
    ["decision", "决策", `${(graph.decision?.duration_ms ?? 0) / 1000} 秒投票`],
  ];
  const nodes: Json[] = definitions.map(([id, title, detail], i) => ({
    id: "phase:" + id,
    type: "story",
    position: { x: i * 300, y: 100 },
    data: {
      title,
      kind: "阶段",
      detail,
      path: id === "decision" ? ["decision"] : ["timing"],
    },
  }));
  const edges: Json[] = definitions.slice(1).map((_, i) => ({
    id: "phase:" + i,
    source: "phase:" + definitions[i][0],
    target: "phase:" + definitions[i + 1][0],
    label: "推进",
    type: "smoothstep",
    deletable: false,
  }));
  (graph.decision?.options ?? []).forEach((option: string, i: number) => {
    const ending = graph.decision.endings?.[option];
    nodes.push({
      id: "option:" + option,
      type: "story",
      position: { x: 1200, y: i * 150 },
      data: {
        title: graph.option_labels?.[option] ?? option,
        kind: "结局",
        detail: ending ?? "尚未指定结局",
        path: ["decision"],
      },
    });
    edges.push({
      id: "option:" + option,
      source: "phase:decision",
      target: "option:" + option,
      label: "投票结果",
      type: "smoothstep",
      deletable: false,
    });
  });
  return { nodes, edges };
}
