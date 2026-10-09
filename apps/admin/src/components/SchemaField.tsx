import { useState } from "react";
import {
  Button,
  Checkbox,
  Input,
  InputNumber,
  Select,
  Space,
  Switch,
  Typography,
} from "antd";
import {
  DeleteOutlined,
  PlusOutlined,
  ArrowUpOutlined,
  ArrowDownOutlined,
} from "@ant-design/icons";
import { defaultValue, labels, resolveSchema } from "../graph";
import type { Json } from "../api";
export function SchemaField({
  schema,
  value,
  onChange,
  disabled = false,
  depth = 0,
}: {
  schema: Json;
  value: any;
  onChange: (v: any) => void;
  disabled?: boolean;
  depth?: number;
}) {
  schema = resolveSchema(schema);
  const [key, setKey] = useState("");
  if (depth > 12)
    return <Typography.Text type="danger">结构层级超过限制</Typography.Text>;
  if (schema.const !== undefined)
    return (
      <Typography.Text type="secondary">
        {Array.isArray(schema.const)
          ? schema.const.join(" → ")
          : String(schema.const)}
      </Typography.Text>
    );
  if (schema.oneOf) {
    const variants = schema.oneOf as Json[];
    let index = variants.findIndex(
      (s) =>
        (s.required ?? []).every((k: string) => value?.[k] !== undefined) &&
        Object.entries(s.properties ?? {}).every(
          ([k, v]) =>
            (v as Json).const === undefined || value?.[k] === (v as Json).const,
        ),
    );
    if (index < 0) index = 0;
    return (
      <div className="variant-field">
        <Select
          value={index}
          disabled={disabled}
          style={{ width: "100%" }}
          options={variants.map((s, i) => ({
            value: i,
            label:
              s.properties?.type?.const === "bool"
                ? "布尔变量"
                : s.properties?.type?.const === "int"
                  ? "整数变量"
                  : (labels[s.required?.[0]] ??
                    s.required?.[0] ??
                    `类型 ${i + 1}`),
          }))}
          onChange={(i) => onChange(defaultValue(variants[i]))}
        />
        <SchemaField
          schema={variants[index]}
          value={value ?? defaultValue(variants[index])}
          onChange={onChange}
          disabled={disabled}
          depth={depth + 1}
        />
      </div>
    );
  }
  if (schema.enum)
    return (
      <Select
        value={value}
        disabled={disabled}
        style={{ width: "100%" }}
        options={schema.enum.map((v: any) => ({
          value: v,
          label:
            (
              {
                actor: "仅执行角色",
                public: "所有角色",
                bool: "布尔",
                int: "整数",
                draft: "草稿",
                ready: "已就绪",
                programmatic_demo_ready: "演示素材就绪",
                missing_original_video: "待上传原创视频",
              } as Json
            )[v] ?? String(v),
        }))}
        onChange={onChange}
      />
    );
  if (schema.type === "array") {
    const values: any[] = value ?? [];
    return (
      <div className="array-field">
        {values.map((item, i) => (
          <div className="array-item" key={i}>
            <Space className="array-item-tools">
              <Typography.Text type="secondary">第 {i + 1} 项</Typography.Text>
              <Button
                size="small"
                aria-label={`上移第 ${i + 1} 项`}
                disabled={disabled || i === 0}
                icon={<ArrowUpOutlined />}
                onClick={() => {
                  const next = [...values];
                  [next[i - 1], next[i]] = [next[i], next[i - 1]];
                  onChange(next);
                }}
              />
              <Button
                size="small"
                aria-label={`下移第 ${i + 1} 项`}
                disabled={disabled || i === values.length - 1}
                icon={<ArrowDownOutlined />}
                onClick={() => {
                  const next = [...values];
                  [next[i + 1], next[i]] = [next[i], next[i + 1]];
                  onChange(next);
                }}
              />
              <Button
                size="small"
                danger
                aria-label={`删除第 ${i + 1} 项`}
                disabled={disabled}
                icon={<DeleteOutlined />}
                onClick={() => onChange(values.filter((_, j) => j !== i))}
              />
            </Space>
            <SchemaField
              schema={schema.items}
              value={item}
              onChange={(v) =>
                onChange(values.map((old, j) => (j === i ? v : old)))
              }
              disabled={disabled}
              depth={depth + 1}
            />
          </div>
        ))}
        <Button
          icon={<PlusOutlined />}
          disabled={disabled || values.length >= (schema.maxItems ?? 100)}
          onClick={() => onChange([...values, defaultValue(schema.items)])}
        >
          添加一项
        </Button>
      </div>
    );
  }
  if (schema.type === "object") {
    const data = value ?? {};
    const properties = schema.properties ?? {};
    const fields = schema.properties
      ? Object.keys(properties)
      : Object.keys(data);
    const required = schema.required ?? [];
    const update = (name: string, v: any) => onChange({ ...data, [name]: v });
    return (
      <div className="object-field">
        {fields.map((name) => {
          const optional = !!schema.properties && !required.includes(name);
          const field = properties[name] ?? schema.additionalProperties;
          if (!field || field === true) return null;
          return (
            <div className="property-field" key={name}>
              <div className="property-label">
                <Typography.Text strong>{labels[name] ?? name}</Typography.Text>
                {optional ? (
                  <Checkbox
                    disabled={disabled}
                    checked={data[name] !== undefined}
                    onChange={(e) => {
                      if (e.target.checked) update(name, defaultValue(field));
                      else {
                        const next = { ...data };
                        delete next[name];
                        onChange(next);
                      }
                    }}
                  >
                    启用
                  </Checkbox>
                ) : !schema.properties ? (
                  <Button
                    size="small"
                    danger
                    type="text"
                    aria-label={`删除 ${name}`}
                    disabled={disabled}
                    icon={<DeleteOutlined />}
                    onClick={() => {
                      const next = { ...data };
                      delete next[name];
                      onChange(next);
                    }}
                  />
                ) : null}
              </div>
              {(!optional || data[name] !== undefined) && (
                <SchemaField
                  schema={field}
                  value={data[name] ?? defaultValue(field)}
                  onChange={(v) => update(name, v)}
                  disabled={disabled}
                  depth={depth + 1}
                />
              )}
            </div>
          );
        })}
        {!schema.properties && schema.additionalProperties && (
          <Space.Compact className="map-add">
            <Input
              aria-label="新增条目编号"
              placeholder="新条目编号，如 C4"
              value={key}
              onChange={(e) => setKey(e.target.value)}
              disabled={disabled}
            />
            <Button
              icon={<PlusOutlined />}
              disabled={
                disabled ||
                !/^([A-Za-z][A-Za-z0-9_]{0,63})$/.test(key) ||
                Object.hasOwn(data, key) ||
                Object.keys(data).length >= (schema.maxProperties ?? 100)
              }
              onClick={() => {
                update(key, defaultValue(schema.additionalProperties));
                setKey("");
              }}
            >
              添加
            </Button>
          </Space.Compact>
        )}
      </div>
    );
  }
  const type = Array.isArray(schema.type)
    ? typeof value === "boolean"
      ? "boolean"
      : "integer"
    : schema.type;
  if (type === "boolean")
    return (
      <Space>
        <Switch checked={!!value} disabled={disabled} onChange={onChange} />
        {Array.isArray(schema.type) && (
          <Button size="small" disabled={disabled} onClick={() => onChange(0)}>
            改为整数
          </Button>
        )}
      </Space>
    );
  if (type === "integer")
    return (
      <Space>
        <InputNumber
          value={value ?? 0}
          disabled={disabled}
          precision={0}
          min={schema.minimum}
          max={schema.maximum}
          onChange={(v) => {
            if (v !== null) onChange(v);
          }}
        />
        {Array.isArray(schema.type) && (
          <Button
            size="small"
            disabled={disabled}
            onClick={() => onChange(false)}
          >
            改为布尔
          </Button>
        )}
      </Space>
    );
  if ((schema.maxLength ?? 0) > 200)
    return (
      <Input.TextArea
        value={value ?? ""}
        disabled={disabled}
        maxLength={schema.maxLength}
        rows={4}
        onChange={(e) => onChange(e.target.value)}
      />
    );
  return (
    <Input
      value={value ?? ""}
      disabled={disabled}
      maxLength={schema.maxLength}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}
