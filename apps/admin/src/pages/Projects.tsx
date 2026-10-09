import { useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  App,
  Button,
  Card,
  Form,
  Input,
  InputNumber,
  Modal,
  Space,
  Table,
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
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [form] = Form.useForm();
  async function create() {
    try {
      const values = await form.validateFields();
      setBusy(true);
      const p = await api.c2("POST", "/projects", values);
      await cache.invalidateQueries({ queryKey: ["c2-projects"] });
      navigate(`/studio/${p.id}/world`);
    } catch (e) {
      if (e instanceof Error) void message.error(e.message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <PageTitle
        title="创作项目"
        description="构建可探索的世界，让角色的行动改变故事。"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => setOpen(true)}
          >
            新建项目
          </Button>
        }
      />
      <QueryState query={query}>{null}</QueryState>
      <Card>
        <Table
          rowKey="id"
          dataSource={query.data?.items ?? []}
          columns={[
            {
              title: "项目",
              dataIndex: "title",
              render: (name, p: Json) => (
                <Button
                  type="link"
                  onClick={() => navigate(`/studio/${p.id}/world`)}
                >
                  {name}
                </Button>
              ),
            },
            { title: "简介", dataIndex: "summary", ellipsis: true },
            {
              title: "状态",
              render: (_, p: Json) => (
                <Tag color={p.current_release_id ? "green" : "gold"}>
                  {p.archived_at
                    ? "已归档"
                    : p.current_release_id
                      ? "已发布"
                      : "创作中"}
                </Tag>
              ),
            },
            { title: "修订", dataIndex: "revision" },
            {
              title: "操作",
              render: (_, p: Json) => (
                <Space>
                  <Button onClick={() => navigate(`/studio/${p.id}/world`)}>
                    进入工作室
                  </Button>
                </Space>
              ),
            },
          ]}
        />
      </Card>
      <Modal
        title="新建创作项目"
        open={open}
        onCancel={() => setOpen(false)}
        onOk={create}
        confirmLoading={busy}
        okText="创建并进入世界画布"
      >
        <Form form={form} layout="vertical" initialValues={{ seat_count: 3 }}>
          <Form.Item
            name="title"
            label="项目名称"
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
