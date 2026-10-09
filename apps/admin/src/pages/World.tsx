import { useEffect, useMemo, useRef, useState } from "react";
import { useBlocker, useNavigate, useParams } from "react-router-dom";
import {
  App,
  Alert,
  Button,
  Card,
  Drawer,
  Flex,
  Input,
  List,
  Modal,
  Select,
  Space,
  Spin,
  Switch,
  Tabs,
  Tag,
  Typography,
} from "antd";
import {
  ReactFlow,
  useViewport,
  Background,
  Controls,
  MiniMap,
  Handle,
  Position,
  type NodeProps,
  type Node,
  type Edge,
} from "@xyflow/react";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError, type Json } from "../api";
import { PageTitle, useAuth } from "../shared";
import c3Story from "../../../../contracts/c3/story.schema.json";
import c3Schema from "../../../../contracts/c3/extension.schema.json";
import { C2Field, c2Schema, resolve, seed } from "../components/C2Field";
function LocationNode({ data }: NodeProps) {
  const { zoom } = useViewport();
  return (
    <div className="world-location-node">
      <Handle type="target" position={Position.Left} />
      <div className="location-node-title">
        <span className="location-symbol">⌖</span>
        <strong style={{ fontSize: Math.max(16, 14 / zoom) }}>
          {String(data.label)}
        </strong>
        <small style={{ fontSize: Math.max(12, 12 / zoom) }}>
          {String(data.count ?? 0)} 项内容
        </small>
      </div>
      <p
        className="location-node-summary"
        style={{ fontSize: Math.max(14, 12 / zoom) }}
      >
        {String(data.description ?? "")}
      </p>
      <span
        className="location-node-visibility"
        style={{ fontSize: Math.max(12, 12 / zoom) }}
      >
        {String(data.visibility ?? "")}
      </span>
      <Handle type="source" position={Position.Right} />
    </div>
  );
}
function EntityNode({ data }: NodeProps) {
  return (
    <div className={`world-entity-node entity-${data.kind}`}>
      <span className="entity-symbol">
        {data.kind === "actions" ? "↗" : "◇"}
      </span>
      <div>
        <small>{data.kind === "actions" ? "角色行动" : "场景对象"}</small>
        <strong>{String(data.title)}</strong>
      </div>
      {data.cost !== undefined && (
        <span className="entity-cost">{String(data.cost)} 点</span>
      )}
    </div>
  );
}
const nodeTypes = { location: LocationNode, entity: EntityNode };
const groups: Record<string, string> = {
  passages: "方向通路",
  interactions: "密码与判定",
  locations: "地点",
  links: "通路",
  objects: "对象",
  actions: "行动",
  templates: "自由行动模板",
  events: "事件",
  roles: "角色",
  clues: "知识",
  media: "叙事素材",
  votes: "投票",
};

export function World() {
  const { id } = useParams();
  return <WorldEditor key={id} />;
}
function WorldEditor() {
  const { id, location, interaction } = useParams();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const { message, modal } = App.useApp();
  const [story, setStory] = useState<Json>();
  const [revision, setRevision] = useState(0);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [conflict, setConflict] = useState(false);
  const [selection, setSelection] = useState<{ kind: string; id: string }>();
  const [config, setConfig] = useState<string>();
  const [group, setGroup] = useState("locations");
  const [filter, setFilter] = useState("");
  const [report, setReport] = useState<Json>();
  const [previewRole, setPreviewRole] = useState<string>();
  const [previewFixture, setPreviewFixture] = useState("initial");
  const [preview, setPreview] = useState<Json>();
  const [positions, setPositions] = useState<
    Record<string, { x: number; y: number }>
  >({});
  const [layoutRevision, setLayoutRevision] = useState(0);
  const [layoutDirty, setLayoutDirty] = useState(false);
  const version = useRef(0);
  const saveBusy = useRef(false);
  const undoHistory = useRef<Json[]>([]);
  const redoHistory = useRef<Json[]>([]);
  useEffect(() => {
    if (interaction) setSelection({ kind: "interactions", id: interaction });
  }, [interaction]);
  const draft = useQuery({
    queryKey: ["c2-draft", id],
    queryFn: () => api.c2("GET", `/projects/${id}/draft`),
  });
  const layout = useQuery({
    queryKey: ["c2-layout", id],
    queryFn: () => api.c2("GET", `/projects/${id}/layout`),
  });
  const localKey = `ruxi.c2.draft:${profile?.user_id}:${id}`;
  const blocker = useBlocker(
    ({ nextLocation }) =>
      (dirty || layoutDirty) &&
      !nextLocation.pathname.startsWith(`/stories/${id}/world`),
  );
  useEffect(() => {
    setStory(undefined);
    setSelection(undefined);
    setConflict(false);
    setDirty(false);
    setRevision(0);
  }, [id]);
  useEffect(() => {
    if (!draft.data || story) return;
    setStory(draft.data.content);
    setRevision(draft.data.revision);
    try {
      const raw = localStorage.getItem(localKey);
      if (raw) {
        const local = JSON.parse(raw);
        modal.confirm({
          title: "发现未保存的本地草稿",
          content: "恢复后请检查与服务器修订的差异。",
          okText: "恢复本地修改",
          cancelText: "使用服务器内容",
          onOk: () => {
            setStory(local.content);
            setDirty(true);
            version.current++;
            if (local.revision !== draft.data!.revision) setConflict(true);
          },
          onCancel: () => localStorage.removeItem(localKey),
        });
      }
    } catch {
      void message.warning("本地草稿无法读取");
    }
  }, [draft.data, story, localKey, modal, message]);
  useEffect(() => {
    if (layout.data) {
      setPositions(layout.data.layout?.positions ?? {});
      setLayoutRevision(layout.data.layout_revision ?? layout.data.revision);
    }
  }, [layout.data]);
  function edit(next: Json, record = true) {
    if (record && story) {
      undoHistory.current = [
        ...undoHistory.current.slice(-59),
        structuredClone(story),
      ];
      redoHistory.current = [];
    }
    setStory(next);
    setDirty(true);
    version.current++;
    localStorage.setItem(
      localKey,
      JSON.stringify({ content: next, revision, saved_at: Date.now() }),
    );
  }
  function undo() {
    const previous = undoHistory.current.pop();
    if (previous && story) {
      redoHistory.current.push(structuredClone(story));
      edit(previous, false);
    }
  }
  function redo() {
    const next = redoHistory.current.pop();
    if (next && story) {
      undoHistory.current.push(structuredClone(story));
      edit(next, false);
    }
  }
  function removeSelected() {
    if (!selection || !selected || !story) return;
    const references: string[] = [];
    const visit = (value: any, path: string) => {
      if (
        value === selection.id ||
        (selection.kind === "passages" &&
          (value === `${selection.id}_ab` || value === `${selection.id}_ba`))
      )
        references.push(path);
      else if (Array.isArray(value))
        value.forEach((x, i) => visit(x, `${path}/${i}`));
      else if (value && typeof value === "object")
        Object.entries(value).forEach(([k, v]) => {
          if (k === selection.id) references.push(`${path}/${k}`);
          visit(v, `${path}/${k}`);
        });
    };
    const copy = structuredClone(story);
    const values =
      selection.kind === "passages" || selection.kind === "interactions"
        ? copy.c3
        : copy;
    values[selection.kind] = values[selection.kind].filter(
      (x: Json) => x.id !== selection.id,
    );
    visit(copy, "");
    if (references.length) {
      modal.info({
        title: "先处理引用，再删除",
        content: (
          <div>
            {references.slice(0, 20).map((p) => (
              <p key={p}>{p}</p>
            ))}
          </div>
        ),
      });
      return;
    }
    modal.confirm({
      title: `删除 ${selected.label ?? selected.id}？`,
      content: "会保留在撤销记录中。已经发布的版本不受影响。",
      onOk: () => {
        edit(copy);
        setSelection(undefined);
      },
    });
  }
  async function save() {
    if (!story || saveBusy.current || conflict) return;
    saveBusy.current = true;
    setSaving(true);
    const v = version.current;
    try {
      const result = await api.c2(
        "PUT",
        `/projects/${id}/draft`,
        { content: story },
        revision,
      );
      setRevision(result.revision);
      if (v === version.current) {
        setDirty(false);
        localStorage.removeItem(localKey);
      } else {
        const local = localStorage.getItem(localKey);
        if (local)
          localStorage.setItem(
            localKey,
            JSON.stringify({ ...JSON.parse(local), revision: result.revision }),
          );
      }
    } catch (e) {
      if (e instanceof ApiError && e.code === "REVISION_CONFLICT")
        setConflict(true);
      else if (e instanceof Error) void message.error(e.message);
    } finally {
      saveBusy.current = false;
      setSaving(false);
    }
  }
  useEffect(() => {
    if (!dirty || conflict || saving) return;
    const timer = setTimeout(() => void save(), 2000);
    return () => clearTimeout(timer);
  }, [story, dirty, conflict, saving, revision]);
  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (dirty || layoutDirty) e.preventDefault();
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [dirty, layoutDirty]);
  const { nodes, edges } = useMemo(() => {
    if (!story) return { nodes: [], edges: [] };
    const nodes: Node[] = [];
    const list = location
      ? story.locations.filter((l: Json) => l.id === location)
      : story.locations;
    list.forEach((l: Json, i: number) => {
      const key = `locations:${l.id}`;
      const children = [
        ...(story.objects ?? [])
          .filter((o: Json) => o.location === l.id)
          .map((o: Json) => ({ kind: "objects", item: o })),
        ...(story.actions ?? [])
          .filter((a: Json) => a.location === l.id)
          .map((a: Json) => ({ kind: "actions", item: a })),
      ];
      nodes.push({
        id: key,
        type: "location",
        position: positions[key] ?? {
          x: (i % 3) * 340,
          y: Math.floor(i / 3) * 230,
        },
        data: {
          label: l.label,
          count: children.length,
          description: l.description,
          visibility: l.discovered ? "公开地点" : "需要发现",
        },
        style: {
          width: location ? 310 : 270,
          height: location ? Math.max(180, 80 + children.length * 72) : 154,
          background: "#f8faf5",
          border: "1px solid #cedacc",
          borderRadius: 12,
          padding: 0,
        },
      });
      if (location)
        children.forEach(({ kind, item }, j) => {
          const k = `${kind}:${item.id}`;
          nodes.push({
            id: k,
            type: "entity",
            parentId: key,
            extent: "parent",
            position: positions[k] ?? { x: 20, y: 66 + j * 72 },
            data: {
              kind,
              title: item.label,
              cost: item.cost,
              label: `${groups[kind]} · ${item.label} ${item.cost === undefined ? "" : `/ ${item.cost} 点`}`,
            },
            style: {
              width: 270,
              borderColor: kind === "actions" ? "#769283" : "#bdaf99",
              borderRadius: 9,
              padding: 0,
              border: "1px solid #dfe7dc",
              background: "#fff",
            },
          });
        });
    });
    if (group === "events")
      (story.events ?? []).forEach((e: Json, i: number) =>
        nodes.push({
          id: `events:${e.id}`,
          position: positions[`events:${e.id}`] ?? { x: 1150, y: i * 120 },
          data: { label: `事件 · ${e.label ?? e.id}` },
          style: { width: 240, borderColor: "#b8854b", background: "#fff8e9" },
        }),
      );
    const topology =
      story.schema_version === 4
        ? (story.c3?.passages ?? []).map((p: Json) => ({
            id: p.id,
            from: p.a,
            to: p.b,
            cost: p.ab.cost,
            label: `${p.ab.cost} 点 → ${p.ba ? `← ${p.ba.cost} 点` : "单向"}`,
          }))
        : (story.links ?? []);
    const edges: Edge[] = topology
      .filter((l: Json) => !location)
      .map((l: Json) => ({
        id: l.id,
        source: `locations:${l.from}`,
        target: `locations:${l.to}`,
        label: `${l.label ?? "通路"} · ${l.cost} 点`,
        markerEnd: { type: "arrowclosed" as any },
      }));
    return { nodes, edges };
  }, [story, positions, group, location]);
  async function layoutSave() {
    try {
      const result = await api.c2(
        "PUT",
        `/projects/${id}/layout`,
        { layout: { positions } },
        layoutRevision,
      );
      setLayoutRevision(result.layout_revision ?? result.revision);
      setLayoutDirty(false);
    } catch (e) {
      if (e instanceof Error) void message.error(e.message);
    }
  }
  function add() {
    if (!story) return;
    const itemSchema = groupSchema(group);
    const item = seed(itemSchema);
    item.id = `${group.slice(0, -1)}_${crypto.randomUUID().slice(0, 8)}`;
    if ("location" in item) item.location = story.locations[0]?.id ?? "";
    if (location && "location" in item) item.location = location;
    updateCollection(group, [...collection(group), item]);
    setSelection({ kind: group, id: item.id });
  }
  function collection(kind: string): Json[] {
    return (
      (kind === "passages" || kind === "interactions"
        ? story?.c3?.[kind]
        : story?.[kind]) ?? []
    );
  }
  function groupSchema(kind: string): Json {
    return kind === "passages" || kind === "interactions"
      ? (c3Schema.properties as Json)[kind].items
      : resolve(
          (story?.schema_version === 4 ? c3Story : c2Schema).properties[kind],
          story?.schema_version === 4 ? c3Story : c2Schema,
        ).items;
  }
  function updateCollection(kind: string, items: Json[]) {
    if (!story) return;
    edit(
      kind === "passages" || kind === "interactions"
        ? { ...story, c3: { ...story.c3, [kind]: items } }
        : { ...story, [kind]: items },
    );
  }
  const selected =
    selection &&
    collection(selection.kind).find((x: Json) => x.id === selection.id);
  if (!story)
    return draft.isError ? (
      <Alert type="error" message={draft.error.message} />
    ) : (
      <Spin />
    );
  return (
    <>
      <PageTitle
        title={story.title}
        description="世界画布 · 地点、对象与行动共同构成可探索的故事"
        extra={
          <Space wrap>
            <Tag color={conflict ? "red" : dirty ? "gold" : "green"}>
              {conflict
                ? "版本冲突"
                : saving
                  ? "保存中"
                  : dirty
                    ? "未保存"
                    : "已保存"}
            </Tag>
            <Button disabled={!undoHistory.current.length} onClick={undo}>
              撤销
            </Button>
            <Button disabled={!redoHistory.current.length} onClick={redo}>
              重做
            </Button>
            <Button onClick={() => navigate(`/stories/${id}/releases`)}>
              审核与发布
            </Button>
            <Button onClick={() => navigate("/stories")}>返回项目</Button>
            <Button
              disabled={conflict}
              loading={saving}
              onClick={() => void save()}
            >
              立即保存
            </Button>
            <Button onClick={() => void layoutSave()} disabled={!layoutDirty}>
              保存布局
            </Button>
            <Button
              onClick={async () => {
                try {
                  if (dirty) await save();
                  setReport(
                    await api.c2("POST", `/projects/${id}/validate`, {}),
                  );
                } catch (e) {
                  if (e instanceof Error) void message.error(e.message);
                }
              }}
            >
              验证世界
            </Button>
          </Space>
        }
      />
      {conflict && (
        <Alert
          type="warning"
          message="服务器版本已变化，本地修改已保留"
          description="请先导出本地草稿并与服务器内容核对，再重新读取；当前不会覆盖其他作者的修改。"
          action={
            <Button
              onClick={() => {
                const url = URL.createObjectURL(
                  new Blob([JSON.stringify(story, null, 2)], {
                    type: "application/json",
                  }),
                );
                const a = document.createElement("a");
                a.href = url;
                a.download = "world-local-draft.json";
                a.click();
                URL.revokeObjectURL(url);
              }}
            >
              导出本地草稿
            </Button>
          }
        />
      )}
      <Card size="small" style={{ marginBottom: 16 }} title="同伴交流">
        <Space wrap>
          <Switch checked={story.communication?.voice?.enabled === true} onChange={(enabled) => edit({...story, communication: {voice: {enabled, scope: "scene"}}})}/>
          <Typography.Text>启用场景语音（玩家主动加入；单人不连接 RTC）</Typography.Text>
        </Space>
        <Typography.Paragraph type="secondary" style={{ marginBottom: 0, marginTop: 8 }}>仅允许同场景且两两可见的玩家互听；预览不创建 RTC 连接。旧发布版不会自动启用。</Typography.Paragraph>
      </Card>
      <Space style={{ marginBottom: 16 }}>
        <Button onClick={() => setConfig("rules")}>回合与行动点规则</Button>
        <Button onClick={() => setConfig("initial")}>世界变量与初始物品</Button>
        {story.schema_version === 4 && (
          <Button onClick={() => setConfig("c3_settings")}>
            阵营、目标与世界演化
          </Button>
        )}
      </Space>
      <Space className="world-breadcrumb" style={{ marginBottom: 16 }}>
        <Button onClick={() => navigate(`/stories/${id}/world`)}>
          世界地图
        </Button>
        {location && (
          <Tag>
            {story.locations.find((l: Json) => l.id === location)?.label ??
              "地点已删除"}{" "}
            · 场景编辑
          </Tag>
        )}
        {!location && (
          <Typography.Text type="secondary">
            世界层只展示地点与通路。双击地点进入场景。
          </Typography.Text>
        )}
        {story.schema_version === 3 && (
          <Button
            onClick={() => {
              edit({
                ...story,
                schema_version: 4,
                c3: {
                  profile_version: 1,
                  suggested_content_version: 4,
                  map_mode: "mixed",
                  passages: story.links.map((l: Json) => ({
                    id: l.id,
                    a: l.from,
                    b: l.to,
                    barrier_id: null,
                    ab: {
                      enabled: true,
                      cost: l.cost,
                      discover_if: { op: "always" },
                      enter_if: { op: "always" },
                      arrival_events: [],
                    },
                    ba: null,
                  })),
                  interactions: [],
                },
                secrets: {},
                c3_settings: {
                  barriers: {},
                  arrival_rules: {},
                  legacy_passage_conditions: Object.fromEntries(
                    story.links.map((l: Json) => [
                      `${l.id}_ab`,
                      {
                        enter: l.condition,
                        discover:
                          l.discovered === false
                            ? { op: "any", args: [] }
                            : (l.display_condition ?? { op: "all", args: [] }),
                      },
                    ]),
                  ),
                },
              });
            }}
          >
            创建 C3 草稿
          </Button>
        )}
      </Space>
      <Space wrap style={{ marginBottom: 16 }}>
        <Typography.Text>角色视角预览</Typography.Text>
        <Select
          aria-label="预览角色"
          placeholder="选择角色"
          value={previewRole}
          style={{ width: 160 }}
          options={story.roles.map((r: Json) => ({
            value: r.id,
            label: r.label,
          }))}
          onChange={setPreviewRole}
        />
        <Select
          aria-label="预览快照"
          value={previewFixture}
          options={[
            { value: "initial", label: "初始快照" },
            { value: "blocked", label: "封路快照" },
            { value: "repaired", label: "修复快照" },
          ]}
          onChange={setPreviewFixture}
        />
        <Button
          disabled={!previewRole || dirty || conflict}
          onClick={async () => {
            try {
              setPreview(
                await api.c2("POST", `/projects/${id}/projection-preview`, {
                  draft_revision: revision,
                  role_id: previewRole,
                  fixture_id: previewFixture,
                }),
              );
            } catch (e) {
              if (e instanceof Error) void message.error(e.message);
            }
          }}
        >
          查看授权投影
        </Button>
      </Space>
      <Modal
        open={!!preview}
        title={`角色视角 · ${preview?.role_id ?? ""}`}
        onCancel={() => setPreview(undefined)}
        footer={<Button onClick={() => setPreview(undefined)}>返回编辑</Button>}
      >
        <Alert
          message="独立预览，不修改草稿。此窗口仅显示服务器返回的该角色投影。"
          type="info"
        />
        <Typography.Title level={5}>已知地点</Typography.Title>
        <Space wrap>
          {preview?.view.map.locations.map((l: Json) => (
            <Tag key={l.id}>{l.label}</Tag>
          ))}
        </Space>
        <Typography.Title level={5}>可见互动与行动</Typography.Title>
        {[
          ...(preview?.view.actions ?? []),
          ...(preview?.view.interactions ?? []),
        ].map((a: Json) => (
          <p key={a.id}>
            {a.label} · {a.cost} 点
          </p>
        ))}
        <Typography.Title level={5}>已知线索</Typography.Title>
        {preview?.view.knowledge.map((k: Json) => (
          <p key={k.id}>
            {k.label ?? "线索"}：{k.text}
          </p>
        ))}
        <Typography.Title level={5}>个人目标</Typography.Title>
        {preview?.view.self.goals.map((g: string) => (
          <p key={g}>{g}</p>
        ))}
      </Modal>
      <Flex gap={16} className="c2-world-workspace">
        <Card
          size="small"
          style={{ width: 260, flexShrink: 0 }}
          title="内容结构"
          extra={
            <Button size="small" onClick={add}>
              新增
            </Button>
          }
        >
          <Select
            style={{ width: "100%" }}
            value={group}
            onChange={setGroup}
            options={Object.entries(groups)
              .filter(
                ([key]) =>
                  story.schema_version === 4 ||
                  !["passages", "interactions"].includes(key),
              )
              .map(([value, label]) => ({
                value,
                label,
              }))}
          />
          <Input.Search
            placeholder="搜索名称或标识"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            style={{ margin: "12px 0" }}
          />
          <List
            dataSource={collection(group).filter((x: Json) =>
              `${x.label ?? ""} ${x.id}`.includes(filter),
            )}
            renderItem={(x: Json) => (
              <List.Item>
                <Button
                  type="text"
                  onClick={() => setSelection({ kind: group, id: x.id })}
                >
                  {x.label ?? x.id}
                </Button>
              </List.Item>
            )}
          />
        </Card>
        <div
          style={{
            height: "70vh",
            minHeight: 520,
            flex: 1,
            border: "1px solid #d8d6cf",
            borderRadius: 12,
            overflow: "hidden",
          }}
        >
          {location ? (
            <div className="scene-object-grid">
              {collection("objects")
                .filter((o: Json) => o.location === location)
                .map((o: Json) => (
                  <Card
                    key={o.id}
                    title={o.label}
                    extra={
                      <Button
                        onClick={() =>
                          setSelection({ kind: "objects", id: o.id })
                        }
                      >
                        对象 · {o.label}
                      </Button>
                    }
                  >
                    <Typography.Paragraph>
                      {o.description ?? "场景对象"}
                    </Typography.Paragraph>
                    <Space wrap>
                      {collection("actions")
                        .filter((a: Json) => a.target === o.id)
                        .map((a: Json) => (
                          <Button
                            key={a.id}
                            onClick={() =>
                              setSelection({ kind: "actions", id: a.id })
                            }
                          >
                            {a.label} · {a.cost} 点
                          </Button>
                        ))}
                      {collection("interactions")
                        .filter((a: Json) => a.target_id === o.id)
                        .map((a: Json) => (
                          <Button
                            key={a.id}
                            onClick={() =>
                              navigate(
                                `/stories/${id}/world/${location}/interactions/${a.id}`,
                              )
                            }
                          >
                            {a.kind === "password" ? "密码输入" : "骰子判定"} ·{" "}
                            {a.cost} 点
                          </Button>
                        ))}
                    </Space>
                  </Card>
                ))}
              <Card title="场景行动">
                <Space wrap>
                  {collection("actions")
                    .filter((a: Json) => a.location === location && !a.target)
                    .map((a: Json) => (
                      <Button
                        key={a.id}
                        onClick={() =>
                          setSelection({ kind: "actions", id: a.id })
                        }
                      >
                        {a.label} · {a.cost} 点
                      </Button>
                    ))}
                </Space>
              </Card>
            </div>
          ) : (
            <ReactFlow
              nodes={nodes}
              edges={edges}
              fitView
              minZoom={0.75}
              fitViewOptions={{ minZoom: 0.75, maxZoom: 1, padding: 0.15 }}
              onEdgeClick={(_, edge) =>
                setSelection({
                  kind: story.schema_version === 4 ? "passages" : "links",
                  id: edge.id,
                })
              }
              onNodeDoubleClick={(_, node) => {
                if (node.type === "location")
                  navigate(`/stories/${id}/world/${node.id.slice(10)}`);
              }}
              onNodeClick={(_, node) => {
                const [kind, ...rest] = node.id.split(":");
                setSelection({ kind, id: rest.join(":") });
              }}
              onNodeDragStop={(_, node) => {
                setPositions((p) => ({ ...p, [node.id]: node.position }));
                setLayoutDirty(true);
              }}
              onNodesChange={(changes) => {
                const moved = changes.filter(
                  (c) => c.type === "position" && c.position,
                );
                if (moved.length)
                  setPositions((p) => {
                    const next = { ...p };
                    for (const c of moved)
                      if (c.type === "position" && c.position)
                        next[c.id] = c.position;
                    return next;
                  });
              }}
              nodesConnectable={false}
              deleteKeyCode={null}
            >
              <Background color="#dad5c9" gap={24} />
              <Controls />
              <MiniMap />
            </ReactFlow>
          )}
        </div>
      </Flex>
      <Drawer
        title={
          config === "rules"
            ? "回合与行动点规则"
            : config === "c3_settings"
              ? "阵营、目标与世界演化"
              : "世界变量与初始物品"
        }
        open={!!config}
        onClose={() => setConfig(undefined)}
        width={460}
      >
        {config && (
          <C2Field
            schema={
              (story.schema_version === 4 ? c3Story : c2Schema).properties[
                config
              ]
            }
            root={story.schema_version === 4 ? c3Story : c2Schema}
            value={story[config]}
            change={(v) => edit({ ...story, [config]: v })}
          />
        )}
      </Drawer>
      <Drawer
        title={
          selection
            ? `${groups[selection.kind]} · ${selected?.label ?? selection.id}`
            : "属性"
        }
        open={!!selected}
        onClose={() => {
          setSelection(undefined);
          if (interaction) navigate(`/stories/${id}/world/${location}`);
        }}
        width={460}
      >
        {selected && (
          <Button danger style={{ marginBottom: 16 }} onClick={removeSelected}>
            删除实体
          </Button>
        )}
        {selected && selection?.kind === "locations" && (
          <Space direction="vertical" style={{ marginBottom: 16, width: "100%" }}>
            <Typography.Text>场景语音</Typography.Text>
            <Select aria-label="场景语音策略" value={selected.voice?.mode ?? "inherit"} options={[{value:"inherit",label:"继承剧目设置"},{value:"disabled",label:"禁用（隐藏或非对称场景）"}]} onChange={(mode)=>updateCollection("locations", story.locations.map((x: Json)=>x.id===selected.id ? {...x,voice:{mode}} : x))} style={{ width: "100%" }}/>
          </Space>
        )}
        {selected && selection?.kind === "locations" && (
          <Button
            style={{ marginBottom: 16 }}
            onClick={() => {
              navigate(`/stories/${id}/world/${selection.id}`);
              setSelection(undefined);
            }}
          >
            进入场景编辑
          </Button>
        )}
        {selected &&
          selection?.kind === "interactions" &&
          selected.kind === "password" && (
            <Input.Password
              aria-label="谜题答案（仅作者）"
              placeholder="仅制作使用，不进入玩家包"
              value={story.secrets?.[selected.answer_secret_ref]?.answer ?? ""}
              onChange={(e) =>
                edit({
                  ...story,
                  secrets: {
                    ...story.secrets,
                    [selected.answer_secret_ref]: {
                      ...story.secrets?.[selected.answer_secret_ref],
                      answer: e.target.value,
                      aliases: [],
                    },
                  },
                })
              }
              style={{ marginBottom: 16 }}
            />
          )}
        {selected && selection && (
          <C2Field
            schema={groupSchema(selection.kind)}
            root={story.schema_version === 4 ? c3Story : c2Schema}
            value={selected}
            change={(v) => {
              if (v.id !== selection.id) {
                void message.warning("标识重命名需要同步引用，请保持标识不变");
                v.id = selection.id;
              }
              updateCollection(
                selection.kind,
                collection(selection.kind).map((x: Json) =>
                  x.id === selection.id ? v : x,
                ),
              );
            }}
          />
        )}
      </Drawer>
      <Modal
        open={!!report}
        title="世界验证"
        onCancel={() => setReport(undefined)}
        footer={<Button onClick={() => setReport(undefined)}>关闭</Button>}
      >
        <Alert
          type={report?.valid ? "success" : "warning"}
          message={
            report?.valid ? "规则结构与引用检查通过" : "需要修复以下问题"
          }
        />
        <List
          dataSource={report?.errors ?? []}
          renderItem={(x: Json) => (
            <List.Item>
              <Typography.Text>
                {x.pointer} · {x.message ?? x.code}
              </Typography.Text>
            </List.Item>
          )}
        />
      </Modal>
      <Modal
        open={blocker.state === "blocked"}
        title="有未保存的修改"
        onCancel={() => blocker.reset?.()}
        onOk={() => blocker.proceed?.()}
        okText="保留本地草稿并离开"
        cancelText="继续编辑"
      >
        尚未保存的内容保留在此浏览器，布局修改请先保存。
      </Modal>
    </>
  );
}
