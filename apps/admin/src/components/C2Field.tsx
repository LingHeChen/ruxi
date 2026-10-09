import { useState } from "react";
import {
  Button,
  Input,
  InputNumber,
  Select,
  Space,
  Switch,
  Typography,
} from "antd";
import schema from "../../../../contracts/c2/story.schema.json";
import type { Json } from "../api";
export const c2Schema: Json = schema;
export function resolve(s: Json): Json {
  return s.$ref
    ? s.$ref
        .slice(2)
        .split("/")
        .reduce((v: Json, k: string) => v[k], c2Schema)
    : s;
}
export function seed(s: Json): any {
  s = resolve(s);
  if (s.const !== undefined) return structuredClone(s.const);
  if (s.default !== undefined) return structuredClone(s.default);
  if (s.enum) return s.enum[0];
  if (s.oneOf) return seed(s.oneOf[0]);
  if (Array.isArray(s.type))
    return s.type.includes("null") ? null : seed({ ...s, type: s.type[0] });
  if (s.type === "object")
    return Object.fromEntries(
      (s.required ?? []).map((k: string) => [k, seed(s.properties[k])]),
    );
  if (s.type === "array") return [];
  if (s.type === "integer") return s.minimum ?? 0;
  if (s.type === "boolean") return false;
  return "";
}
const names: Record<string, string> = {
  ap_per_round: "每回合行动点",
  step_timeout_sec: "行动等待秒数",
  proposal_ttl_sec: "提案有效秒数",
  round_limit: "最大回合数",
  id: "标识",
  label: "名称",
  location: "所在地点",
  condition: "执行条件",
  display_condition: "展示条件",
  effects: "结果",
  cost: "行动点",
  summary: "文字摘要",
  goals: "角色目标",
  knowledge: "初始知识",
  from: "起点",
  to: "终点",
  discovered: "初始可见",
  risk: "风险说明",
  target: "目标",
  tags: "标签",
  required_tags: "目标标签",
  required_participants: "协作人数",
  max_uses: "使用次数",
  success_threshold: "成功阈值",
  audience: "受众",
  trigger: "触发时机",
  priority: "优先级",
  once: "仅触发一次",
  op: "操作",
  ref: "引用",
  value: "值",
  args: "条件组",
  blocking: "等待确认",
  kind: "类型",
  uri: "素材地址",
};
export function C2Field({
  schema: raw,
  value,
  change,
  depth = 0,
  label = "字段",
}: {
  schema: Json;
  value: any;
  change: (v: any) => void;
  depth?: number;
  label?: string;
}) {
  const [newKey, setNewKey] = useState("");
  const s = resolve(raw);
  if (depth > 14)
    return (
      <Typography.Text type="danger">结构过深，请简化条件</Typography.Text>
    );
  const field = (x: Json, v: any, fn: (v: any) => void, fieldLabel = label) => (
    <C2Field
      schema={x}
      value={v}
      change={fn}
      depth={depth + 1}
      label={fieldLabel}
    />
  );
  if (s.const !== undefined)
    return (
      <Typography.Text type="secondary">{String(s.const)}</Typography.Text>
    );
  if (s.oneOf) {
    let index = s.oneOf.findIndex((raw: Json) => {
      const x = resolve(raw);
      return (
        (!x.type ||
          (x.type === "object"
            ? value !== null && typeof value === "object"
            : x.type === "integer"
              ? Number.isInteger(value)
              : typeof value === x.type)) &&
        Object.entries(x.properties ?? {}).every(
          ([k, p]) =>
            (p as Json).const === undefined || value?.[k] === (p as Json).const,
        )
      );
    });
    if (index < 0) index = 0;
    return (
      <Space orientation="vertical" style={{ width: "100%" }}>
        <Select
          style={{ width: "100%" }}
          value={index}
          options={s.oneOf.map((x: Json, i: number) => ({
            value: i,
            label:
              resolve(x).properties?.op?.const ??
              resolve(x).type ??
              `类型 ${i + 1}`,
          }))}
          onChange={(i) => change(seed(s.oneOf[i]))}
        />
        {field(s.oneOf[index], value, change)}
      </Space>
    );
  }
  if (Array.isArray(s.type))
    return (
      <Space orientation="vertical" style={{ width: "100%" }}>
        <Switch
          checked={value !== null}
          checkedChildren="设置"
          unCheckedChildren="无"
          onChange={(yes) =>
            change(
              yes
                ? seed({ ...s, type: s.type.find((x: string) => x !== "null") })
                : null,
            )
          }
        />
        {value !== null &&
          field(
            { ...s, type: s.type.find((x: string) => x !== "null") },
            value,
            change,
          )}
      </Space>
    );
  if (s.enum)
    return (
      <Select
        style={{ width: "100%" }}
        value={value}
        options={s.enum.map((v: any) => ({ value: v, label: String(v) }))}
        onChange={change}
      />
    );
  if (s.type === "boolean")
    return <Switch checked={value === true} onChange={change} />;
  if (s.type === "integer" || s.type === "number")
    return (
      <InputNumber
        aria-label={label}
        value={value}
        min={s.minimum}
        max={s.maximum}
        precision={s.type === "integer" ? 0 : undefined}
        onChange={(v) => change(v ?? 0)}
      />
    );
  if (s.type === "array")
    return (
      <Space orientation="vertical" style={{ width: "100%" }}>
        {(value ?? []).map((v: any, i: number) => (
          <div key={i} className="c2-array-item">
            {field(s.items, v, (next) =>
              change(
                value.map((old: any, j: number) => (j === i ? next : old)),
              ),
            )}
            <Button
              danger
              size="small"
              onClick={() =>
                change(value.filter((_: any, j: number) => j !== i))
              }
            >
              删除这一项
            </Button>
          </div>
        ))}
        <Button onClick={() => change([...(value ?? []), seed(s.items)])}>
          添加
        </Button>
      </Space>
    );
  if (s.type === "object") {
    if (!s.properties)
      return (
        <Space orientation="vertical" style={{ width: "100%" }}>
          {Object.entries(value ?? {}).map(([k, v]) => (
            <div key={k}>
              <Typography.Text strong>{k}</Typography.Text>
              {field(s.additionalProperties, v, (next) =>
                change({ ...value, [k]: next }),
              )}
              <Button
                danger
                size="small"
                onClick={() => {
                  const next = { ...value };
                  delete next[k];
                  change(next);
                }}
              >
                删除字段
              </Button>
            </div>
          ))}
          <Space>
            <Input
              aria-label="新增字段名称"
              placeholder="变量或角色标识"
              value={newKey}
              onChange={(e) => setNewKey(e.target.value)}
            />
            <Button
              disabled={
                !/^[a-z][a-z0-9_]*$/.test(newKey) ||
                Object.hasOwn(value ?? {}, newKey)
              }
              onClick={() => {
                change({ ...value, [newKey]: seed(s.additionalProperties) });
                setNewKey("");
              }}
            >
              添加字段
            </Button>
          </Space>
        </Space>
      );
    return (
      <Space orientation="vertical" style={{ width: "100%" }}>
        {Object.entries(s.properties).map(([k, x]) => (
          <div key={k}>
            <Typography.Text strong>{names[k] ?? k}</Typography.Text>
            {!(s.required ?? []).includes(k) && value?.[k] === undefined ? (
              <Button
                size="small"
                onClick={() => change({ ...value, [k]: seed(x as Json) })}
              >
                设置
              </Button>
            ) : (
              field(
                x as Json,
                value?.[k],
                (v) => change({ ...value, [k]: v }),
                names[k] ?? k,
              )
            )}
          </div>
        ))}
      </Space>
    );
  }
  return (
    <Input.TextArea
      autoSize={{ minRows: 1, maxRows: 8 }}
      value={value ?? ""}
      onChange={(e) => change(e.target.value)}
    />
  );
}
