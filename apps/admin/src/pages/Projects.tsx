import { useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  App,
  Button,
  Card,
  Empty,
  Segmented,
  Typography,
  Flex,
  Form,
  Input,
  InputNumber,
  Modal,
  Tag,
} from "antd";
import { PlusOutlined } from "@ant-design/icons";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type Json } from "../api";
import { PageTitle, QueryState } from "../shared";

export function Projects() {
  const navigate = useNavigate();
  const { message } = App.useApp();
  const cache = useQueryClient();
  const query = useQuery({
    queryKey: ["c2-projects"],
    queryFn: () => api.c2("GET", "/projects"),
  });
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("全部");
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [form] = Form.useForm();
  const visible = (query.data?.items ?? []).filter(
    (p: Json) =>
      `${p.title} ${p.summary}`.includes(search) &&
      (status === "全部" || status === "已归档"
        ? status === "全部" || !!p.archived_at
        : !p.archived_at &&
          (status === "已发布"
            ? !!p.current_release_id
            : !p.current_release_id)),
  );
  async function create() {
    try {
      const values = await form.validateFields();
      setBusy(true);
      const p = await api.c2("POST", "/projects", values);
      await cache.invalidateQueries({ queryKey: ["c2-projects"] });
      navigate(`/stories/${p.id}/world`);
    } catch (e) {
      if (e instanceof Error) void message.error(e.message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <PageTitle
        title="剧目管理"
        description="从一个想法开始，创作下一部值得入戏的故事。"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => setOpen(true)}
          >
            新建剧目
          </Button>
        }
      />
      <div className="library-hero">
        <div>
          <span className="eyebrow">STORY STUDIO</span>
          <h2>好故事，始于你的世界。</h2>
          <p>编排角色的选择，让每一次行动都有回响。</p>
        </div>
        <div className="hero-orbit" aria-hidden="true">
          <span>入</span>
          <span>戏</span>
        </div>
      </div>
      <Flex justify="space-between" gap={16} wrap className="library-toolbar">
        <Segmented
          options={["全部", "创作中", "已发布", "已归档"]}
          value={status}
          onChange={(v) => setStatus(String(v))}
        />
        <Input.Search
          placeholder="搜索剧目名称或简介"
          aria-label="搜索剧目"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ maxWidth: 320 }}
        />
      </Flex>
      <QueryState query={query}>
        <div className="story-library">
          {visible.map((p: Json, i: number) => (
            <Card
              className="studio-story-card"
              key={p.id}
              cover={
                <div className={`story-cover cover-${i % 4}`}>
                  <div className="cover-frame" />
                  <span className="cover-mark">{p.title.slice(0, 2)}</span>
                  <span className="cover-category">
                    {(
                      {
                        mystery: "悬疑推理",
                        emotion: "情感沉浸",
                        scifi: "科幻想象",
                        adventure: "冒险探索",
                      } as Json
                    )[p.category] ?? "互动故事"}
                  </span>
                  <Tag>
                    {p.archived_at
                      ? "已归档"
                      : p.current_release_id
                        ? "已发布"
                        : "创作中"}
                  </Tag>
                </div>
              }
            >
              <Typography.Title level={4}>{p.title}</Typography.Title>
              <p className="story-excerpt">
                {p.summary || "故事尚待书写。进入工作台，构建角色与世界。"}
              </p>
              <div className="story-meta">
                <span>{p.seat_count ?? "—"} 位角色</span>
                <span>{p.location_count ?? 0} 个地点</span>
              </div>
              <Flex
                justify="space-between"
                align="center"
                className="story-card-actions"
              >
                <span className="secondary">
                  {p.updated_at
                    ? new Date(p.updated_at).toLocaleDateString()
                    : "最近创建"}
                </span>
                <Button
                  type="primary"
                  onClick={() => navigate(`/stories/${p.id}/world`)}
                >
                  进入工作台 →
                </Button>
              </Flex>
            </Card>
          ))}
          {!visible.length && (
            <Empty
              description={
                query.data?.items?.length
                  ? "没有匹配的剧目，试试其他筛选条件"
                  : "还没有剧目，从你的第一个故事开始"
              }
            />
          )}
        </div>
      </QueryState>
      <Modal
        title="新建剧目"
        open={open}
        onCancel={() => setOpen(false)}
        onOk={create}
        confirmLoading={busy}
        okText="创建并进入世界画布"
      >
        <Form form={form} layout="vertical" initialValues={{ seat_count: 3 }}>
          <Form.Item
            name="title"
            label="剧目名称"
            rules={[{ required: true, whitespace: true, max: 120 }]}
          >
            <Input maxLength={120} />
          </Form.Item>
          <Form.Item name="summary" label="一句话简介">
            <Input.TextArea maxLength={2000} />
          </Form.Item>
          <Form.Item
            name="seat_count"
            label="角色人数"
            rules={[{ required: true }]}
          >
            <InputNumber min={2} max={4} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
