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
  Tabs,
  Tag,
  Typography,
} from "antd";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
} from "@xyflow/react";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError, type Json } from "../api";
import { PageTitle, useAuth } from "../shared";
import { C2Field, c2Schema, resolve, seed } from "../components/C2Field";
const groups: Record<string, string> = {
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
  const { id } = useParams();
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
  const [positions, setPositions] = useState<
    Record<string, { x: number; y: number }>
  >({});
  const [layoutRevision, setLayoutRevision] = useState(0);
  const [layoutDirty, setLayoutDirty] = useState(false);
  const version = useRef(0);
  const saveBusy = useRef(false);
  const draft = useQuery({
    queryKey: ["c2-draft", id],
    queryFn: () => api.c2("GET", `/projects/${id}/draft`),
  });
  const layout = useQuery({
    queryKey: ["c2-layout", id],
    queryFn: () => api.c2("GET", `/projects/${id}/layout`),
  });
  const localKey = `ruxi.c2.draft:${profile?.user_id}:${id}`;
  const blocker = useBlocker(dirty || layoutDirty);
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
  function edit(next: Json) {
    setStory(next);
    setDirty(true);
    version.current++;
    localStorage.setItem(
      localKey,
      JSON.stringify({ content: next, revision, saved_at: Date.now() }),
    );
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
    story.locations.forEach((l: Json, i: number) => {
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
        position: positions[key] ?? {
          x: (i % 3) * 370,
          y: Math.floor(i / 3) * 430,
        },
        data: { label: l.label },
        style: {
          width: 310,
          height: Math.max(180, 70 + children.length * 64),
          background: "#faf8f1",
          border: "1px solid #b8ac91",
          borderRadius: 12,
          padding: 14,
        },
      });
      children.forEach(({ kind, item }, j) => {
        const k = `${kind}:${item.id}`;
        nodes.push({
          id: k,
          parentId: key,
          extent: "parent",
          position: positions[k] ?? { x: 20, y: 60 + j * 64 },
          data: {
            label: `${groups[kind]} · ${item.label} ${item.cost === undefined ? "" : `/ ${item.cost} 点`}`,
          },
          style: {
            width: 270,
            borderColor: kind === "actions" ? "#769283" : "#bdaf99",
            borderRadius: 8,
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
    const edges: Edge[] = (story.links ?? []).map((l: Json) => ({
      id: l.id,
      source: `locations:${l.from}`,
      target: `locations:${l.to}`,
      label: `${l.label ?? "通路"} · ${l.cost} 点`,
      markerEnd: { type: "arrowclosed" as any },
    }));
    return { nodes, edges };
  }, [story, positions, group]);
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
    const itemSchema = resolve(c2Schema.properties[group]).items;
    const item = seed(itemSchema);
    item.id = `${group.slice(0, -1)}_${crypto.randomUUID().slice(0, 8)}`;
    if ("location" in item) item.location = story.locations[0]?.id ?? "";
    edit({ ...story, [group]: [...(story[group] ?? []), item] });
    setSelection({ kind: group, id: item.id });
  }
  const selected =
    selection &&
    story?.[selection.kind]?.find((x: Json) => x.id === selection.id);
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
          <Space>
            <Tag color={conflict ? "red" : dirty ? "gold" : "green"}>
              {conflict
                ? "版本冲突"
                : saving
                  ? "保存中"
                  : dirty
                    ? "未保存"
                    : "已保存"}
            </Tag>
            <Button onClick={() => navigate(`/studio/${id}/releases`)}>
              审核与发布
            </Button>
            <Button onClick={() => navigate("/studio/projects")}>
              返回项目
            </Button>
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
      <Space style={{ marginBottom: 16 }}>
        <Button onClick={() => setConfig("rules")}>回合与行动点规则</Button>
        <Button onClick={() => setConfig("initial")}>世界变量与初始物品</Button>
      </Space>
      <Tabs activeKey="world" items={[{ key: "world", label: "世界" }]} />
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
            options={Object.entries(groups).map(([value, label]) => ({
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
            dataSource={(story[group] ?? []).filter((x: Json) =>
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
          <ReactFlow
            nodes={nodes}
            edges={edges}
            fitView
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
        </div>
      </Flex>
      <Drawer
        title={config === "rules" ? "回合与行动点规则" : "世界变量与初始物品"}
        open={!!config}
        onClose={() => setConfig(undefined)}
        width={460}
      >
        {config && (
          <C2Field
            schema={c2Schema.properties[config]}
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
        onClose={() => setSelection(undefined)}
        width={460}
      >
        {selected && selection && (
          <C2Field
            schema={resolve(c2Schema.properties[selection.kind]).items}
            value={selected}
            change={(v) => {
              if (v.id !== selection.id) {
                void message.warning("标识重命名需要同步引用，请保持标识不变");
                v.id = selection.id;
              }
              edit({
                ...story,
                [selection.kind]: story[selection.kind].map((x: Json) =>
                  x.id === selection.id ? v : x,
                ),
              });
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
