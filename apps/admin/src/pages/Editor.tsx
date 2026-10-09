import { useEffect, useMemo, useState } from "react";
import { useParams, useNavigate, useBlocker } from "react-router-dom";
import {
  Alert,
  App,
  Button,
  Card,
  Collapse,
  Input,
  Select,
  Space,
  Tabs,
  Tag,
  Typography,
  Descriptions,
  List,
} from "antd";
import {
  ReactFlow,
  useNodesState,
  Background,
  Controls,
  MiniMap,
  Handle,
  Position,
  type NodeProps,
  type Node,
} from "@xyflow/react";
import { api, command, type Json } from "../api";
import {
  PageTitle,
  QueryState,
  useApi,
  useAuth,
  JsonView,
  statusNames,
} from "../shared";
import {
  buildRelations,
  buildPhases,
  graphSchema,
  resolveSchema,
  setGraphPath,
  validateGraph,
} from "../graph";
import { SchemaField } from "../components/SchemaField";
function StoryNode({ data }: NodeProps) {
  return (
    <div className="story-node">
      <Handle type="target" position={Position.Left} />
      <small>{String(data.kind)}</small>
      <strong>{String(data.title)}</strong>
      <span>{String(data.detail)}</span>
      <Handle type="source" position={Position.Right} />
    </div>
  );
}
const nodeTypes = { story: StoryNode };
function GraphCanvas({
  diagram,
  layoutKey,
  onSelect,
}: {
  diagram: { nodes: Json[]; edges: Json[] };
  layoutKey: string;
  onSelect: (data: Json) => void;
}) {
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>([]);
  useEffect(() => {
    let positions: Json = {};
    try {
      positions = JSON.parse(localStorage.getItem(layoutKey) ?? "{}");
    } catch {}
    setNodes(
      diagram.nodes.map((node) => ({
        ...node,
        position: positions[node.id] ?? node.position,
      })) as any,
    );
  }, [diagram, layoutKey, setNodes]);
  return (
    <ReactFlow
      nodes={nodes}
      edges={diagram.edges as any}
      onNodesChange={onNodesChange}
      nodeTypes={nodeTypes}
      fitView
      nodesConnectable={false}
      deleteKeyCode={null}
      onNodeClick={(_, node) => onSelect(node.data)}
      onNodeDragStop={(_, node) => {
        let positions: Json = {};
        try {
          positions = JSON.parse(localStorage.getItem(layoutKey) ?? "{}");
        } catch {}
        positions[node.id] = node.position;
        try {
          localStorage.setItem(layoutKey, JSON.stringify(positions));
        } catch {}
      }}
    >
      <Background gap={24} />
      <Controls />
      <MiniMap />
    </ReactFlow>
  );
}
export function Editor() {
  const { versionId } = useParams();
  const navigate = useNavigate();
  const auth = useAuth();
  const query = useApi(`/v1/admin/versions/${versionId}`, !!versionId);
  const assets = useApi("/v1/admin/assets", !!versionId);
  const [availability, setAvailability] = useState("available"),
    [availabilityReason, setAvailabilityReason] = useState("");
  const [graph, setGraph] = useState<Json | null>(null),
    [past, setPast] = useState<Json[]>([]),
    [future, setFuture] = useState<Json[]>([]),
    [selected, setSelected] = useState<Json | null>(null),
    [mode, setMode] = useState("relations"),
    [busy, setBusy] = useState(false),
    [report, setReport] = useState<Json | null>(null),
    [preview, setPreview] = useState<Json | null>(null),
    [aiJob, setAiJob] = useState<Json | null>(null),
    [instruction, setInstruction] = useState(""),
    [target, setTarget] = useState("title"),
    [media, setMedia] = useState<string>();
  const { message, modal } = App.useApp();
  useEffect(() => {
    setGraph(null);
    setAiJob(null);
  }, [versionId]);
  const dirty =
    !!graph && JSON.stringify(graph) !== JSON.stringify(query.data?.graph);
  const frozen = query.data?.status === "published";
  const blocker = useBlocker(dirty);
  useEffect(() => {
    if (blocker.state === "blocked") {
      const dialog = modal.confirm({
        title: "草稿尚未保存",
        content: "离开会丢失当前未保存的修改。",
        okText: "放弃修改并离开",
        cancelText: "继续编辑",
        onOk: () => blocker.proceed(),
        onCancel: () => blocker.reset(),
      });
      return () => dialog.destroy();
    }
  }, [blocker.state]);
  useEffect(() => {
    if (query.data) {
      setGraph(structuredClone(query.data.graph));
      setPast([]);
      setFuture([]);
      setSelected(null);
      setPreview(null);
      setReport(null);
    }
  }, [query.data]);
  useEffect(() => {
    if (!dirty) return;
    const guard = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    window.addEventListener("beforeunload", guard);
    return () => window.removeEventListener("beforeunload", guard);
  }, [dirty]);
  useEffect(() => {
    if (!aiJob || ["completed", "failed"].includes(aiJob.status)) return;
    let active = true;
    const timer = setInterval(() => {
      api
        .request("GET", `/v1/admin/ai/jobs/${aiJob.job_id}`)
        .then((result) => {
          if (active) setAiJob(result);
        })
        .catch((e) => {
          if (active) {
            message.error(e.message);
            setAiJob({ ...aiJob, status: "failed" });
          }
        });
    }, 2000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [aiJob?.job_id, aiJob?.status]);
  const change = (next: Json) => {
    if (!graph || frozen) return;
    setPast((p) => [...p.slice(-49), graph]);
    setFuture([]);
    setGraph(next);
    setReport(null);
    setPreview(null);
  };
  const run = async (fn: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      message.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const post = () => ({ ...command(), revision: query.data.revision });
  const diagram = useMemo(
    () =>
      graph
        ? mode === "phases"
          ? buildPhases(graph)
          : buildRelations(graph)
        : { nodes: [], edges: [] },
    [graph, mode],
  );
  const layoutKey = `ruxi.admin.layout.${auth.profile?.user_id}.${versionId}.${mode}`;
  const schemaAt = (path: (string | number)[]) =>
    path.reduce((s, key) => {
      s = resolveSchema(s);
      return typeof key === "number"
        ? s.items
        : (s.properties?.[key] ?? s.additionalProperties ?? { type: "string" });
    }, graphSchema);
  if (!versionId)
    return (
      <>
        <PageTitle
          title="内容工作室"
          description="选择剧目草稿，编辑剧情、线索与素材。"
        />
        <Card>
          <Button type="primary" onClick={() => navigate("/stories")}>
            选择剧目
          </Button>
        </Card>
      </>
    );
  return (
    <>
      <PageTitle
        title={graph?.title ?? "内容工作室"}
        description={`版本 ${versionId} · 修订 ${query.data?.revision ?? "—"}`}
        extra={
          <Space>
            <Tag>{statusNames[query.data?.status] ?? query.data?.status}</Tag>
            {dirty && <Tag color="gold">未保存</Tag>}
            <Button
              disabled={!past.length || frozen}
              onClick={() => {
                setFuture((f) => [graph!, ...f]);
                setGraph(past.at(-1)!);
                setPast(past.slice(0, -1));
              }}
            >
              撤销
            </Button>
            <Button
              disabled={!future.length || frozen}
              onClick={() => {
                setPast((p) => [...p, graph!]);
                setGraph(future[0]);
                setFuture(future.slice(1));
              }}
            >
              重做
            </Button>
            <Button
              type="primary"
              loading={busy}
              disabled={!dirty || frozen}
              onClick={() =>
                run(async () => {
                  await api.request("PUT", `/v1/admin/versions/${versionId}`, {
                    revision: query.data.revision,
                    graph,
                  });
                  await query.refetch();
                  message.success("草稿已保存");
                })
              }
            >
              保存草稿
            </Button>
          </Space>
        }
      />
      <QueryState query={query}>
        {graph && (
          <>
            {frozen && (
              <Alert
                className="section-card"
                type="info"
                showIcon
                title="此版本已发布并冻结"
                description="请在剧目管理中创建新版本后修改内容。"
              />
            )}
            <Tabs
              items={[
                {
                  key: "canvas",
                  label: "剧情画布",
                  children: (
                    <div className="editor-grid">
                      <Card
                        title="剧情关系"
                        extra={
                          <Select
                            value={mode}
                            onChange={(v) => {
                              setMode(v);
                              setSelected(null);
                            }}
                            options={[
                              { value: "relations", label: "角色、行动与线索" },
                              { value: "phases", label: "阶段与结局" },
                            ]}
                          />
                        }
                      >
                        <div className="flow-canvas">
                          <GraphCanvas
                            diagram={diagram}
                            layoutKey={layoutKey}
                            onSelect={setSelected}
                          />
                        </div>
                        <Typography.Text type="secondary">
                          点击节点编辑属性；拖动节点调整布局。阶段顺序由游戏协议固定，布局仅保存在当前浏览器。
                        </Typography.Text>
                      </Card>
                      <Card
                        title={
                          selected
                            ? `${selected.kind} · ${selected.title}`
                            : "节点属性"
                        }
                      >
                        {selected ? (
                          <SchemaField
                            schema={schemaAt(selected.path)}
                            value={selected.path.reduce(
                              (v: any, k: string | number) => v?.[k],
                              graph,
                            )}
                            disabled={frozen}
                            onChange={(v) =>
                              change(setGraphPath(graph, selected.path, v))
                            }
                          />
                        ) : (
                          <Typography.Paragraph type="secondary">
                            选择画布中的角色、行动或线索，查看并编辑它的内容。行动条件和结果会同步更新连线。
                          </Typography.Paragraph>
                        )}
                      </Card>
                    </div>
                  ),
                },
                {
                  key: "fields",
                  label: "完整内容编辑",
                  children: (
                    <Card>
                      <Collapse
                        items={Object.entries(graphSchema.properties).map(
                          ([key, schema]) => ({
                            key,
                            label:
                              (
                                {
                                  title: "剧目名称",
                                  role_definitions: "角色介绍",
                                  actions: "行动与条件",
                                  clues: "线索",
                                  decision: "投票与结局",
                                  assets: "片段素材",
                                } as Json
                              )[key] ?? key,
                            children: (
                              <SchemaField
                                schema={schema as Json}
                                value={graph[key]}
                                disabled={
                                  frozen ||
                                  [
                                    "schema_version",
                                    "story_id",
                                    "phases",
                                  ].includes(key)
                                }
                                onChange={(value) =>
                                  change({ ...graph, [key]: value })
                                }
                              />
                            ),
                          }),
                        )}
                      />
                    </Card>
                  ),
                },
                {
                  key: "production",
                  label: "素材与 AI 辅助",
                  children: (
                    <Space orientation="vertical" className="full-width">
                      <Card title="片段素材绑定">
                        {graph.assets.map((slot: Json, index: number) => (
                          <div className="asset-binding" key={slot.media_id}>
                            <strong>{slot.media_id}</strong>
                            <Select
                              className="full-width"
                              disabled={frozen}
                              placeholder="选择已就绪素材"
                              value={
                                assets.data?.items?.some(
                                  (a: Json) => a.asset_id === slot.asset_id,
                                )
                                  ? slot.asset_id
                                  : undefined
                              }
                              options={(assets.data?.items ?? [])
                                .filter((a: Json) => a.status === "ready")
                                .map((a: Json) => ({
                                  value: a.asset_id,
                                  label: a.filename ?? a.asset_id,
                                }))}
                              onChange={(id) => {
                                const asset = assets.data.items.find(
                                  (a: Json) => a.asset_id === id,
                                );
                                change(
                                  setGraphPath(graph, ["assets", index], {
                                    ...slot,
                                    asset_id: id,
                                    sha256: asset.sha256,
                                    duration_ms: asset.duration_ms,
                                    source: asset.rights_source ?? slot.source,
                                  }),
                                );
                              }}
                            />
                          </div>
                        ))}
                      </Card>
                      <Card title="AI 制作建议">
                        <Space orientation="vertical" className="full-width">
                          <Select
                            value={target}
                            onChange={setTarget}
                            options={[
                              { value: "title", label: "剧目标题" },
                              { value: "asset_summary", label: "片段摘要" },
                            ]}
                          />
                          {target === "asset_summary" && (
                            <Select
                              placeholder="选择片段"
                              value={media}
                              onChange={setMedia}
                              options={graph.media.map((id: string) => ({
                                value: id,
                                label: id,
                              }))}
                            />
                          )}
                          <Input.TextArea
                            value={instruction}
                            onChange={(e) => setInstruction(e.target.value)}
                            maxLength={500}
                            rows={3}
                            placeholder="描述希望改善的方向"
                          />
                          <Button
                            disabled={
                              dirty ||
                              frozen ||
                              (target === "asset_summary" && !media)
                            }
                            loading={
                              busy ||
                              (!!aiJob &&
                                !["completed", "failed"].includes(aiJob.status))
                            }
                            onClick={() =>
                              run(async () => {
                                setAiJob(
                                  await api.request(
                                    "POST",
                                    `/v1/admin/versions/${versionId}/ai`,
                                    {
                                      ...post(),
                                      target,
                                      instruction,
                                      ...(target === "asset_summary"
                                        ? { media_id: media }
                                        : {}),
                                    },
                                  ),
                                );
                              })
                            }
                          >
                            生成建议
                          </Button>
                          {dirty && (
                            <Typography.Text type="secondary">
                              保存草稿后才能生成建议。
                            </Typography.Text>
                          )}
                          {aiJob && (
                            <>
                              <Tag>{aiJob.status}</Tag>
                              {aiJob.proposal ? (
                                <>
                                  <Typography.Paragraph>
                                    原文：{aiJob.proposal.original}
                                  </Typography.Paragraph>
                                  <Typography.Paragraph>
                                    建议：{aiJob.proposal.suggested}
                                  </Typography.Paragraph>
                                  <Button
                                    disabled={dirty || frozen}
                                    onClick={() =>
                                      run(async () => {
                                        await api.request(
                                          "POST",
                                          `/v1/admin/ai/jobs/${aiJob.job_id}/apply`,
                                          post(),
                                        );
                                        await query.refetch();
                                        setAiJob(null);
                                        message.success("建议已应用到新修订");
                                      })
                                    }
                                  >
                                    应用建议
                                  </Button>
                                </>
                              ) : (
                                <JsonView
                                  value={
                                    aiJob.outcome ??
                                    aiJob.error ?? { status: aiJob.status }
                                  }
                                />
                              )}
                            </>
                          )}
                        </Space>
                      </Card>
                    </Space>
                  ),
                },
                {
                  key: "release",
                  label: "校验与发布",
                  children: (
                    <Card title="版本验收">
                      <Space wrap>
                        <Button
                          disabled={dirty}
                          loading={busy}
                          onClick={() =>
                            run(async () => {
                              if (!validateGraph(graph)) {
                                setReport({
                                  valid: false,
                                  errors: validateGraph.errors,
                                });
                                return;
                              }
                              const job = await api.request(
                                "POST",
                                `/v1/admin/versions/${versionId}/validate`,
                                post(),
                              );
                              setReport(
                                await api.request(
                                  "GET",
                                  `/v1/admin/jobs/${job.job_id}`,
                                ),
                              );
                            })
                          }
                        >
                          校验内容
                        </Button>
                        <Button
                          disabled={dirty}
                          onClick={() =>
                            run(async () =>
                              setPreview(
                                await api.request(
                                  "POST",
                                  `/v1/admin/versions/${versionId}/preview`,
                                  post(),
                                ),
                              ),
                            )
                          }
                        >
                          启动多角色预演
                        </Button>
                        {auth.profile?.roles.includes("reviewer") && (
                          <Button
                            disabled={dirty || frozen}
                            onClick={() =>
                              run(async () => {
                                await api.request(
                                  "POST",
                                  `/v1/admin/versions/${versionId}/approve`,
                                  { ...post(), content_hash: query.data.hash },
                                );
                                await query.refetch();
                                message.success("审核通过");
                              })
                            }
                          >
                            审核通过
                          </Button>
                        )}
                        {auth.profile?.roles.includes("publisher") && (
                          <Button
                            type="primary"
                            disabled={dirty || query.data.status !== "approved"}
                            onClick={() =>
                              modal.confirm({
                                title: "发布此版本？",
                                content:
                                  "发布后内容冻结，玩家将能创建该剧目的房间。",
                                onOk: () =>
                                  run(async () => {
                                    await api.request(
                                      "POST",
                                      `/v1/admin/versions/${versionId}/publish`,
                                      {
                                        ...post(),
                                        approved_hash: query.data.hash,
                                      },
                                    );
                                    await query.refetch();
                                    message.success("版本已发布");
                                  }),
                              })
                            }
                          >
                            正式发布
                          </Button>
                        )}
                      </Space>
                      {dirty && (
                        <Alert
                          className="section-card"
                          type="warning"
                          title="请先保存草稿再进行校验、预演或审核"
                        />
                      )}
                      {report && (
                        <Alert
                          className="section-card"
                          showIcon
                          type={report.valid ? "success" : "error"}
                          title={report.valid ? "内容校验通过" : "内容存在问题"}
                          description={
                            <>
                              <Typography.Paragraph>
                                {report.assets_ready
                                  ? "素材已就绪"
                                  : "请检查素材是否就绪"}{" "}
                                · 可达结局：
                                {report.reachable_endings?.join("、") ?? "—"}
                              </Typography.Paragraph>
                              {(report.errors ?? []).map(
                                (error: any, i: number) => (
                                  <Typography.Paragraph key={i}>
                                    {typeof error === "string"
                                      ? error
                                      : JSON.stringify(error)}
                                  </Typography.Paragraph>
                                ),
                              )}
                            </>
                          }
                        />
                      )}{" "}
                      {frozen && auth.profile?.roles.includes("publisher") && (
                        <Card className="section-card" title="已发布版本可用性">
                          <Space wrap>
                            <Select
                              value={availability}
                              onChange={setAvailability}
                              options={[
                                { value: "available", label: "可发现" },
                                { value: "unlisted", label: "不列出" },
                                { value: "blocked", label: "停用" },
                              ]}
                            />
                            <Input
                              placeholder="调整原因"
                              value={availabilityReason}
                              onChange={(e) =>
                                setAvailabilityReason(e.target.value)
                              }
                            />
                            <Button
                              disabled={!availabilityReason.trim()}
                              onClick={() =>
                                run(async () => {
                                  await api.request(
                                    "POST",
                                    `/v1/admin/versions/${versionId}/availability`,
                                    {
                                      ...command(),
                                      availability,
                                      reason: availabilityReason,
                                    },
                                  );
                                  message.success("可用性已更新");
                                })
                              }
                            >
                              更新可用性
                            </Button>
                          </Space>
                        </Card>
                      )}{" "}
                      {preview && (
                        <Preview
                          preview={preview}
                          busy={busy}
                          onStep={(role, type, payload, extra = {}) =>
                            run(async () =>
                              setPreview(
                                await api.request(
                                  "POST",
                                  "/v1/admin/previews/step",
                                  {
                                    preview_token: preview.preview_token,
                                    actor_role: role,
                                    type,
                                    payload,
                                    ...command(),
                                    ...extra,
                                  },
                                ),
                              ),
                            )
                          }
                        />
                      )}
                    </Card>
                  ),
                },
              ]}
            />
          </>
        )}
      </QueryState>
    </>
  );
}
function Preview({
  preview,
  busy,
  onStep,
}: {
  preview: Json;
  busy: boolean;
  onStep: (role: string, type: string, payload: Json, extra?: Json) => void;
}) {
  return (
    <Card className="section-card" title="多角色预演">
      <Tabs
        items={Object.entries(preview.views ?? {}).map(
          ([role, view]: [string, any]) => ({
            key: role,
            label: view.own_role?.title ?? role,
            children: (
              <>
                <Space wrap>
                  {(view.media?.authorized ?? []).map((m: Json) => (
                    <Button
                      key={m.media_id}
                      disabled={busy}
                      onClick={() =>
                        onStep(role, "media_complete", {
                          media_id: m.media_id,
                          media_epoch: m.media_epoch,
                          mode: "summary",
                        })
                      }
                    >
                      确认 {m.media_id}
                    </Button>
                  ))}
                  {(view.available_actions ?? []).map((a: Json) => (
                    <Button
                      key={a.action_id ?? a.id}
                      disabled={busy || a.enabled !== true}
                      onClick={() =>
                        onStep(role, "investigate", {
                          action_id: a.action_id ?? a.id,
                        })
                      }
                    >
                      {a.label ?? a.action_id ?? a.id}
                    </Button>
                  ))}
                  <Button
                    disabled={busy}
                    onClick={() => onStep(role, "confirm_exploration_end", {})}
                  >
                    结束探索
                  </Button>
                  <Button
                    disabled={busy}
                    onClick={() =>
                      onStep(role, "request_hint", { hint_level: 1 })
                    }
                  >
                    请求提示
                  </Button>
                  <Button
                    disabled={busy}
                    onClick={() =>
                      onStep(role, "advance_time", { delta_ms: 30000 })
                    }
                  >
                    推进 30 秒
                  </Button>
                  {(view.own_clues ?? []).map((c: Json) => (
                    <Button
                      key={c.clue_id}
                      disabled={
                        busy ||
                        c.shared ||
                        c.clue_id === "C2" ||
                        view.room?.phase_code !== "exploration" ||
                        view.room?.exploration_step !== "active"
                      }
                      onClick={() =>
                        onStep(role, "share_clue", { clue_id: c.clue_id })
                      }
                    >
                      公开 {c.clue_id}
                    </Button>
                  ))}
                  {(view.visible_items ?? [])
                    .filter(
                      (item: Json) =>
                        item.owner_membership_id === view.self?.membership_id,
                    )
                    .flatMap((item: Json) =>
                      (view.members ?? [])
                        .filter(
                          (member: Json) =>
                            member.membership_id !== view.self?.membership_id,
                        )
                        .map((member: Json) => (
                          <Button
                            key={item.item_id + member.membership_id}
                            disabled={busy}
                            onClick={() =>
                              onStep(
                                role,
                                "offer_item",
                                {
                                  item_id: item.item_id,
                                  to_member: member.membership_id,
                                },
                                { target_version: item.version },
                              )
                            }
                          >
                            交付 {item.item_id} 给 {member.role_code}
                          </Button>
                        )),
                    )}
                  {(view.offers ?? [])
                    .filter(
                      (offer: Json) =>
                        offer.status === "pending" &&
                        offer.to_member === view.self?.membership_id,
                    )
                    .map((offer: Json) => (
                      <Space key={offer.offer_id}>
                        <Button
                          disabled={busy}
                          onClick={() =>
                            onStep(role, "accept_offer", {
                              offer_id: offer.offer_id,
                            })
                          }
                        >
                          接受交付
                        </Button>
                        <Button
                          disabled={busy}
                          onClick={() =>
                            onStep(role, "reject_offer", {
                              offer_id: offer.offer_id,
                            })
                          }
                        >
                          拒绝交付
                        </Button>
                      </Space>
                    ))}
                  {(view.vote_round?.display_options ?? []).map((o: any) => (
                    <Button
                      key={o.option_id ?? o}
                      disabled={
                        busy ||
                        o.eligible !== true ||
                        view.room?.phase_code !== "decision"
                      }
                      onClick={() =>
                        onStep(role, "vote", {
                          round_id: view.vote_round.round_id,
                          option_id: o.option_id ?? o,
                        })
                      }
                    >
                      投票 {o.label ?? o.option_id ?? o}
                    </Button>
                  ))}
                </Space>
                <Descriptions
                  className="section-card"
                  items={[
                    {
                      key: "phase",
                      label: "阶段",
                      children:
                        statusNames[view.room?.phase_code] ??
                        view.room?.phase_code,
                    },
                    {
                      key: "state",
                      label: "状态",
                      children:
                        statusNames[view.room?.lifecycle] ??
                        view.room?.lifecycle,
                    },
                    {
                      key: "ending",
                      label: "结局",
                      children: view.room?.ending_code ?? "尚未结束",
                    },
                    {
                      key: "vote",
                      label: "我的投票",
                      children: view.own_vote?.option_id ?? "尚未投票",
                    },
                  ]}
                />
                <List
                  header="仅自己知道的线索"
                  dataSource={view.own_clues ?? []}
                  locale={{ emptyText: "尚未发现线索" }}
                  renderItem={(clue: Json) => (
                    <List.Item>
                      <List.Item.Meta
                        title={
                          <Space>
                            {clue.title}
                            <Tag>{clue.shared ? "已公开" : "私有"}</Tag>
                          </Space>
                        }
                        description={clue.text}
                      />
                    </List.Item>
                  )}
                />
                <List
                  header="公开线索"
                  dataSource={view.public_scene?.shared_clues ?? []}
                  locale={{ emptyText: "尚无线索公开" }}
                  renderItem={(clue: Json) => (
                    <List.Item>
                      <List.Item.Meta
                        title={clue.title}
                        description={clue.text}
                      />
                    </List.Item>
                  )}
                />
                <List
                  header="已收到的提示"
                  dataSource={view.hints?.entries ?? []}
                  locale={{ emptyText: "暂无提示" }}
                  renderItem={(hint: Json) => (
                    <List.Item>{hint.text}</List.Item>
                  )}
                />
              </>
            ),
          }),
        )}
      />
      <Collapse
        items={[
          {
            key: "history",
            label: "预演操作记录",
            children: <JsonView value={preview.history ?? preview.steps} />,
          },
        ]}
      />
    </Card>
  );
}
