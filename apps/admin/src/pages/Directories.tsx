import { useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  App,
  Alert,
  Button,
  Card,
  Checkbox,
  Col,
  Flex,
  Form,
  Input,
  Modal,
  Popconfirm,
  Row,
  Select,
  Space,
  Statistic,
  Table,
  Tag,
  Typography,
} from "antd";
import { PlusOutlined, ReloadOutlined } from "@ant-design/icons";
import { useQueryClient } from "@tanstack/react-query";
import { api, command, type Json } from "../api";
import {
  categories,
  difficulties,
  PageTitle,
  QueryState,
  roleNames,
  statusNames,
  useApi,
  useAuth,
} from "../shared";

export function Dashboard() {
  const { profile } = useAuth();
  const navigate = useNavigate();
  const canEdit = profile!.roles.includes("editor");
  const canReview = profile!.roles.includes("reviewer");
  const stories = useApi("/v1/admin/stories", canEdit);
  const operations = useApi("/v1/admin/operations", canReview);
  const reports = useApi("/v1/admin/chat/reports", canReview);
  const query = useQueryClient();
  const data = operations.data;
  const totalRooms = (data?.rooms ?? []).reduce(
    (n: number, r: Json) => n + r.count,
    0,
  );
  return (
    <>
      <PageTitle
        title="工作概览"
        description="让每一个故事，从创作走向开场。"
        extra={
          <Button
            icon={<ReloadOutlined />}
            onClick={() => query.invalidateQueries()}
          >
            刷新数据
          </Button>
        }
      />
      <Row gutter={[20, 20]}>
        {[
          ["剧目总数", canEdit ? (stories.data?.items.length ?? "—") : "—"],
          [
            "已发布剧目",
            canEdit
              ? (stories.data?.items.filter((s: Json) => s.current_version_id)
                  .length ?? "—")
              : "—",
          ],
          ["房间记录", canReview ? (data ? totalRooms : "—") : "—"],
          ["待处理举报", canReview ? (reports.data?.items.length ?? "—") : "—"],
        ].map(([title, value]) => (
          <Col xs={12} xl={6} key={title as string}>
            <Card>
              <Statistic title={title} value={value} />
            </Card>
          </Col>
        ))}
      </Row>
      <Card className="section-card" title="今天从哪里开始？">
        <Flex gap={16} wrap>
          {canEdit && (
            <>
              <Button
                size="large"
                type="primary"
                onClick={() => navigate("/stories")}
              >
                管理剧目与草稿
              </Button>
              <Button size="large" onClick={() => navigate("/assets")}>
                整理原创素材
              </Button>
            </>
          )}
          {canReview && (
            <Button size="large" onClick={() => navigate("/reports")}>
              处理玩家举报
            </Button>
          )}
        </Flex>
        <Space className="role-tags">
          {profile!.roles.map((r) => (
            <Tag key={r}>{roleNames[r]}</Tag>
          ))}
        </Space>
      </Card>
      {canEdit && stories.isError && (
        <Alert type="error" title={stories.error.message} />
      )}
      {canReview && (
        <QueryState query={operations}>
          <Row gutter={[20, 20]}>
            {["rooms", "work", "outcomes"].map((section) => (
              <Col xs={24} xl={8} key={section}>
                <Card
                  title={
                    {
                      rooms: "房间状态",
                      work: "任务状态",
                      outcomes: "终局结果",
                    }[section]
                  }
                >
                  <Table<Json>
                    rowKey={(_, i) => String(i)}
                    size="small"
                    pagination={false}
                    dataSource={data?.[section] ?? []}
                    columns={[
                      {
                        title: "类型",
                        render: (_, r: Json) =>
                          statusNames[r.kind ?? r.lifecycle ?? r.ending_code] ??
                          r.kind ??
                          r.lifecycle ??
                          r.ending_code,
                      },
                      {
                        title: "状态",
                        render: (_, r: Json) => statusNames[r.status] ?? "—",
                      },
                      { title: "数量", dataIndex: "count" },
                    ]}
                  />
                </Card>
              </Col>
            ))}
          </Row>
          <Card className="section-card" title="服务运行">
            <Row gutter={24}>
              <Col>
                <Statistic
                  title="待发送投影"
                  value={data?.outbox_pending ?? 0}
                />
              </Col>
              <Col>
                <Statistic
                  title="最长等待"
                  value={data?.oldest_outbox_age_ms ?? 0}
                  suffix="ms"
                />
              </Col>
              <Col>
                <Statistic
                  title="运行内存"
                  value={(data?.runtime?.memory_bytes ?? 0) / 1048576}
                  precision={1}
                  suffix="MiB"
                />
              </Col>
            </Row>
          </Card>
        </QueryState>
      )}
    </>
  );
}
export function Stories() {
  const query = useApi("/v1/admin/stories");
  const [search, setSearch] = useState(""),
    [editing, setEditing] = useState<Json | null>(null),
    [creating, setCreating] = useState(false),
    [busy, setBusy] = useState(false);
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const { message } = App.useApp();
  const submit = async (values: Json) => {
    setBusy(true);
    try {
      if (editing) {
        await api.request(
          "PUT",
          `/v1/admin/stories/${editing.story_id}/metadata`,
          { ...values, ...command() },
        );
        setEditing(null);
        await query.refetch();
        message.success("展示设置已保存");
      } else {
        const story = await api.request("POST", "/v1/admin/stories", {
          title: values.title,
          summary: values.summary,
          seat_count: 3,
          ...command(),
        });
        const version = await api.request(
          "POST",
          `/v1/admin/stories/${story.story_id}/versions`,
          command(),
        );
        const draft = await api.request(
          "GET",
          `/v1/admin/versions/${version.version_id}`,
        );
        await api.request("PUT", `/v1/admin/versions/${version.version_id}`, {
          revision: draft.revision,
          graph: { ...draft.graph, title: values.title },
        });
        setCreating(false);
        await query.refetch();
        navigate("/editor/" + version.version_id);
      }
    } catch (e) {
      message.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const open = async (story: Json) => {
    setBusy(true);
    try {
      const versions = await api.request(
        "GET",
        `/v1/admin/stories/${story.story_id}/versions`,
      );
      if (versions.items.length)
        navigate(
          "/editor/" +
            (
              versions.items.find((v: Json) => v.status !== "published") ??
              versions.items[0]
            ).version_id,
        );
      else {
        const draft = await api.request(
          "POST",
          `/v1/admin/stories/${story.story_id}/versions`,
          command(),
        );
        navigate("/editor/" + draft.version_id);
      }
    } catch (e) {
      message.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <PageTitle
        title="剧目管理"
        description="管理故事目录、内容版本与对外展示。"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => {
              form.resetFields();
              setCreating(true);
            }}
          >
            创建剧目
          </Button>
        }
      />
      <Card>
        <Input.Search
          placeholder="搜索剧目名称或简介"
          aria-label="搜索剧目"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="directory-search"
        />
        <QueryState query={query}>
          <Table<Json>
            expandable={{
              expandedRowRender: (story) => <VersionList story={story} />,
            }}
            rowKey="story_id"
            scroll={{ x: 850 }}
            dataSource={(query.data?.items ?? []).filter((s: Json) =>
              (s.title + s.summary)
                .toLowerCase()
                .includes(search.toLowerCase()),
            )}
            columns={[
              {
                title: "剧目",
                dataIndex: "title",
                render: (title, r: Json) => (
                  <div>
                    <strong>{title}</strong>
                    <div className="secondary ellipsis">{r.summary}</div>
                  </div>
                ),
              },
              {
                title: "题材",
                dataIndex: "category",
                render: (v) =>
                  categories.find((c) => c.value === v)?.label ?? "—",
                filters: categories.map((c) => ({
                  text: c.label,
                  value: c.value,
                })),
                onFilter: (v, r: Json) => r.category === v,
              },
              { title: "人数", dataIndex: "seat_count", width: 80 },
              {
                title: "状态",
                render: (_, r: Json) => (
                  <Tag color={r.current_version_id ? "green" : "default"}>
                    {r.current_version_id ? "已上线" : "待发布"}
                  </Tag>
                ),
              },
              {
                title: "操作",
                width: 180,
                render: (_, r: Json) => (
                  <Space>
                    <Button type="link" loading={busy} onClick={() => open(r)}>
                      编辑内容
                    </Button>
                    <Button
                      type="link"
                      onClick={() => {
                        form.setFieldsValue(r);
                        setEditing(r);
                      }}
                    >
                      展示设置
                    </Button>
                  </Space>
                ),
              },
            ]}
            pagination={{
              pageSize: 10,
              showSizeChanger: true,
              showTotal: (n) => `共 ${n} 个剧目`,
            }}
          />
        </QueryState>
      </Card>
      <Modal
        title={editing ? "编辑展示设置" : "创建原创剧目"}
        open={!!editing || creating}
        onCancel={() => {
          setEditing(null);
          setCreating(false);
        }}
        onOk={() => form.submit()}
        confirmLoading={busy}
        destroyOnHidden
      >
        <Form
          form={form}
          layout="vertical"
          onFinish={submit}
          initialValues={{
            seat_count: 3,
            summary: "",
            category: "mystery",
            difficulty: "beginner",
          }}
        >
          {!editing ? (
            <>
              <Form.Item
                name="title"
                label="剧目名称"
                rules={[
                  {
                    required: true,
                    max: 120,
                    message: "请输入不超过 120 字的名称",
                  },
                ]}
              >
                <Input maxLength={120} />
              </Form.Item>
              <Form.Item
                name="seat_count"
                label="初始模板人数（可在工作室调整角色与素材）"
              >
                <Select
                  options={[3].map((n) => ({ value: n, label: `${n} 人` }))}
                />
              </Form.Item>
            </>
          ) : (
            <>
              <Form.Item
                name="category"
                label="题材"
                rules={[{ required: true }]}
              >
                <Select options={categories} />
              </Form.Item>
              <Form.Item
                name="difficulty"
                label="难度"
                rules={[{ required: true }]}
              >
                <Select options={difficulties} />
              </Form.Item>
            </>
          )}
          <Form.Item name="summary" label="故事简介" rules={[{ max: 1000 }]}>
            <Input.TextArea rows={4} maxLength={1000} showCount />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
export function Users() {
  const query = useApi("/v1/admin/users");
  const { profile } = useAuth();
  const [target, setTarget] = useState<Json | null>(null),
    [roles, setRoles] = useState<string[]>([]),
    [busy, setBusy] = useState(false),
    [search, setSearch] = useState("");
  const { message } = App.useApp();
  const queryClient = useQueryClient();
  return (
    <>
      <PageTitle
        title="用户目录"
        description="查看最近 100 位用户及其后台权限。"
        extra={
          <Button icon={<ReloadOutlined />} onClick={() => query.refetch()}>
            刷新
          </Button>
        }
      />
      <Card>
        <Input.Search
          className="directory-search"
          placeholder="搜索账号或昵称"
          onChange={(e) => setSearch(e.target.value)}
        />
        <QueryState query={query}>
          <Table
            rowKey="user_id"
            scroll={{ x: 700 }}
            dataSource={(query.data?.items ?? []).filter((u: Json) =>
              `${u.username ?? ""} ${u.display_name ?? ""}`.includes(search),
            )}
            columns={[
              { title: "用户", dataIndex: "display_name" },
              {
                title: "账号",
                dataIndex: "username",
                render: (v) => v ?? "游客",
              },
              {
                title: "状态",
                dataIndex: "status",
                render: (v) => <Tag>{v === "active" ? "正常" : v}</Tag>,
              },
              { title: "参与房间", dataIndex: "room_count" },
              {
                title: "后台权限",
                dataIndex: "roles",
                render: (v: string[]) =>
                  v?.map((r) => <Tag key={r}>{roleNames[r] ?? r}</Tag>),
              },
              {
                title: "操作",
                render: (_, u: Json) => (
                  <Button
                    type="link"
                    disabled={
                      !profile!.roles.includes("publisher") || !u.username
                    }
                    onClick={() => {
                      setTarget(u);
                      setRoles(u.roles ?? []);
                    }}
                  >
                    设置权限
                  </Button>
                ),
              },
            ]}
          />
        </QueryState>
      </Card>
      <Modal
        title={`设置 ${target?.display_name ?? ""} 的后台权限`}
        open={!!target}
        confirmLoading={busy}
        onCancel={() => setTarget(null)}
        onOk={async () => {
          setBusy(true);
          try {
            await api.request(
              "POST",
              `/v1/admin/users/${target!.user_id}/roles`,
              { roles, ...command() },
            );
            if (target!.user_id === profile!.user_id) {
              api.clear();
              queryClient.clear();
            } else await query.refetch();
            setTarget(null);
            message.success("权限已更新，相关后台会话已撤销");
          } catch (e) {
            message.error((e as Error).message);
          } finally {
            setBusy(false);
          }
        }}
      >
        <Typography.Paragraph>
          权限变更后，该用户需要重新登录管理控制台。
        </Typography.Paragraph>
        <Checkbox.Group
          options={Object.entries(roleNames).map(([value, label]) => ({
            value,
            label,
          }))}
          value={roles}
          onChange={setRoles}
        />
      </Modal>
    </>
  );
}
export function Reports() {
  const query = useApi("/v1/admin/chat/reports");
  const { message } = App.useApp();
  const [busy, setBusy] = useState("");
  const review = async (id: string, outcome: string) => {
    setBusy(id);
    try {
      await api.request("POST", `/v1/admin/chat/reports/${id}`, {
        outcome,
        ...command(),
      });
      await query.refetch();
      message.success("举报已处理");
    } catch (e) {
      message.error((e as Error).message);
    } finally {
      setBusy("");
    }
  };
  return (
    <>
      <PageTitle
        title="举报审核"
        description="仅查看玩家主动举报的消息，按处理结果记录审核。"
        extra={<Button onClick={() => query.refetch()}>刷新</Button>}
      />
      <Card>
        <QueryState query={query}>
          <Table
            rowKey="report_id"
            dataSource={query.data?.items ?? []}
            locale={{ emptyText: "暂无待处理举报" }}
            scroll={{ x: 700 }}
            columns={[
              {
                title: "原因",
                dataIndex: "reason",
                render: (v) =>
                  (
                    ({
                      harassment: "辱骂或骚扰",
                      privacy: "泄露隐私",
                      spam: "垃圾信息",
                      other: "其他问题",
                    }) as Json
                  )[v] ?? v,
              },
              {
                title: "举报消息",
                dataIndex: "message_text",
                render: (v) => v ?? "消息已按保留策略清理",
              },
              {
                title: "处理",
                render: (_, r: Json) => (
                  <Space>
                    <Popconfirm
                      title="确认移除这条消息？"
                      onConfirm={() => review(r.report_id, "remove")}
                    >
                      <Button danger loading={busy === r.report_id}>
                        移除消息
                      </Button>
                    </Popconfirm>
                    <Button
                      onClick={() => review(r.report_id, "resolved")}
                      disabled={!!busy}
                    >
                      已处理
                    </Button>
                    <Button
                      onClick={() => review(r.report_id, "dismissed")}
                      disabled={!!busy}
                    >
                      不予受理
                    </Button>
                  </Space>
                ),
              },
            ]}
          />
        </QueryState>
      </Card>
    </>
  );
}

function VersionList({ story }: { story: Json }) {
  const query = useApi(`/v1/admin/stories/${story.story_id}/versions`);
  const navigate = useNavigate();
  const { message } = App.useApp();
  const [busy, setBusy] = useState(false);
  return (
    <QueryState query={query}>
      <Table<Json>
        size="small"
        pagination={false}
        rowKey="version_id"
        dataSource={query.data?.items ?? []}
        columns={[
          { title: "版本编号", dataIndex: "version_id" },
          { title: "修订", dataIndex: "revision" },
          {
            title: "状态",
            dataIndex: "status",
            render: (value) => statusNames[value] ?? value,
          },
          {
            title: "可用性",
            dataIndex: "availability",
            render: (value) =>
              (
                ({
                  available: "可发现",
                  unlisted: "不列出",
                  blocked: "已停用",
                }) as Json
              )[value] ?? value,
          },
          {
            title: "操作",
            render: (_, version: Json) => (
              <Space>
                <Button
                  type="link"
                  onClick={() => navigate("/editor/" + version.version_id)}
                >
                  打开
                </Button>
                <Button
                  type="link"
                  loading={busy}
                  onClick={async () => {
                    setBusy(true);
                    try {
                      const draft = await api.request(
                        "POST",
                        `/v1/admin/stories/${story.story_id}/versions`,
                        { ...command(), base_version_id: version.version_id },
                      );
                      await query.refetch();
                      navigate("/editor/" + draft.version_id);
                    } catch (e) {
                      message.error((e as Error).message);
                    } finally {
                      setBusy(false);
                    }
                  }}
                >
                  复制为新草稿
                </Button>
              </Space>
            ),
          },
        ]}
      />
    </QueryState>
  );
}
