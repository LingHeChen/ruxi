import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  App,
  Alert,
  Button,
  Card,
  Input,
  Modal,
  Space,
  Table,
  Tag,
} from "antd";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type Json } from "../api";
import { PageTitle, QueryState, useAuth } from "../shared";

export function Releases() {
  const { id } = useParams();
  const navigate = useNavigate();
  const cache = useQueryClient();
  const { message } = App.useApp();
  const { profile } = useAuth();
  const draft = useQuery({
    queryKey: ["c2-draft", id],
    queryFn: () => api.c2("GET", `/projects/${id}/draft`),
  });
  const releases = useQuery({
    queryKey: ["c2-releases", id],
    queryFn: () => api.c2("GET", `/projects/${id}/releases`),
  });
  const [operation, setOperation] = useState<{
    action: string;
    release?: string;
  }>();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  async function execute() {
    if (!operation || !draft.data) return;
    setBusy(true);
    try {
      if (operation.action === "publish")
        await api.c2("POST", `/projects/${id}/releases`, {
          content_hash: draft.data.hash,
        });
      else if (operation.action === "approve" || operation.action === "reject")
        await api.c2("POST", `/projects/${id}/reviews`, {
          content_hash: draft.data.hash,
          decision: operation.action,
          reason,
        });
      else
        await api.c2(
          "POST",
          `/releases/${operation.release}/${operation.action}`,
          { reason },
        );
      setOperation(undefined);
      setReason("");
      await cache.invalidateQueries({ queryKey: ["c2-draft", id] });
      await cache.invalidateQueries({ queryKey: ["c2-releases", id] });
      void message.success("操作已完成");
    } catch (e) {
      if (e instanceof Error) void message.error(e.message);
    } finally {
      setBusy(false);
    }
  }
  const reviewed = draft.data?.reviewed_hash === draft.data?.hash;
  return (
    <>
      <PageTitle
        title="审核与发布"
        description="每个发布版本固定内容；已有房间继续使用创建时的版本。"
        extra={
          <Button onClick={() => navigate(`/studio/${id}/world`)}>
            返回世界画布
          </Button>
        }
      />
      <QueryState query={draft}>
        <Card
          title="当前草稿"
          extra={
            <Tag color={reviewed ? "green" : "gold"}>
              {reviewed ? "已审核" : "待审核"}
            </Tag>
          }
        >
          <Alert
            type="info"
            message={`当前修订 ${draft.data?.revision ?? "—"} · ${draft.data?.validation?.valid ? "规则校验通过" : "请先在世界画布验证规则"}`}
          />
          <Space style={{ marginTop: 16 }}>
            {profile?.roles.includes("reviewer") && (
              <>
                <Button onClick={() => setOperation({ action: "approve" })}>
                  审核通过
                </Button>
                <Button onClick={() => setOperation({ action: "reject" })}>
                  退回修改
                </Button>
              </>
            )}
            {profile?.roles.includes("publisher") && (
              <Button
                type="primary"
                disabled={!reviewed}
                onClick={() => setOperation({ action: "publish" })}
              >
                发布当前版本
              </Button>
            )}
          </Space>
        </Card>
      </QueryState>
      <Card title="发布记录" style={{ marginTop: 20 }}>
        <QueryState query={releases}>
          <Table
            rowKey="id"
            dataSource={releases.data?.items ?? []}
            columns={[
              {
                title: "发布时间",
                dataIndex: "published_at",
                render: (v: number) => new Date(v).toLocaleString(),
              },
              {
                title: "版本摘要",
                dataIndex: "content_hash",
                render: (v: string) => v.slice(0, 12),
              },
              {
                title: "状态",
                dataIndex: "status",
                render: (v: string) => (
                  <Tag>
                    {
                      (
                        {
                          published: "已发布",
                          withdrawn: "已撤回",
                          blocked: "已封禁",
                        } as Json
                      )[v]
                    }
                  </Tag>
                ),
              },
              {
                title: "操作",
                render: (_, r: Json) =>
                  profile?.roles.includes("publisher") &&
                  r.status === "published" ? (
                    <Space>
                      <Button
                        onClick={() =>
                          setOperation({ action: "withdraw", release: r.id })
                        }
                      >
                        撤回
                      </Button>
                      <Button
                        danger
                        onClick={() =>
                          setOperation({ action: "block", release: r.id })
                        }
                      >
                        封禁
                      </Button>
                    </Space>
                  ) : null,
              },
            ]}
          />
        </QueryState>
      </Card>
      <Modal
        title={
          operation?.action === "publish"
            ? "发布当前内容"
            : operation?.action === "block"
              ? "封禁版本并暂停活动房间"
              : "记录审核操作"
        }
        open={!!operation}
        confirmLoading={busy}
        onCancel={() => setOperation(undefined)}
        onOk={() => void execute()}
        okButtonProps={{
          disabled: operation?.action !== "publish" && !reason.trim(),
        }}
      >
        {operation?.action === "publish" ? (
          <Alert
            type="info"
            message="新房间将使用当前内容，现有房间的内容保持固定。"
          />
        ) : (
          <Input.TextArea
            aria-label="操作原因"
            placeholder="填写原因，留存于审核记录"
            maxLength={1000}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        )}
      </Modal>
    </>
  );
}
