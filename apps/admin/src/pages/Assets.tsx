import { useState } from "react";
import {
  App,
  Button,
  Card,
  Form,
  Input,
  Modal,
  Space,
  Table,
  Tag,
  Typography,
  Upload,
} from "antd";
import { UploadOutlined, ReloadOutlined } from "@ant-design/icons";
import { api, command, type Json } from "../api";
import { PageTitle, QueryState, statusNames, useApi } from "../shared";
export function Assets() {
  const query = useApi("/v1/admin/assets", true, 5000);
  const [uploading, setUploading] = useState(false),
    [rights, setRights] = useState(""),
    [preview, setPreview] = useState<Json | null>(null),
    [caption, setCaption] = useState<Json | null>(null),
    [vtt, setVtt] = useState(
      "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n请输入字幕。\n",
    ),
    [busy, setBusy] = useState(false);
  const { message } = App.useApp();
  const upload = async (file: File) => {
    if (!rights.trim()) {
      message.error("请先填写版权与来源");
      return false;
    }
    if (
      !["video/mp4", "video/webm", "video/quicktime"].includes(file.type) ||
      file.size > 524288000
    ) {
      message.error("请选择不超过 500 MiB 的 MP4、WebM 或 MOV 视频");
      return false;
    }
    setUploading(true);
    try {
      const bytes = await file.arrayBuffer();
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      const sha256 = Array.from(new Uint8Array(digest), (n) =>
        n.toString(16).padStart(2, "0"),
      ).join("");
      const intent = await api.request(
        "POST",
        "/v1/admin/assets/upload-intents",
        {
          ...command(),
          filename: file.name,
          mime_type: file.type,
          size_bytes: file.size,
          sha256,
        },
      );
      const response = await fetch(intent.upload_url, {
        method: "PUT",
        headers: intent.headers,
        body: bytes,
        signal: AbortSignal.timeout(900000),
      });
      if (!response.ok) throw Error("视频上传失败，请重试");
      await api.request(
        "POST",
        `/v1/admin/assets/${intent.asset_id}/complete`,
        {
          ...command(),
          sha256,
          size_bytes: file.size,
          rights_source: rights.trim(),
        },
      );
      message.success("视频已上传，转码完成后状态会自动更新");
      await query.refetch();
    } catch (e) {
      message.error((e as Error).message);
    } finally {
      setUploading(false);
    }
    return false;
  };
  return (
    <>
      <PageTitle
        title="素材库"
        description="管理原创视频、版权来源和字幕版本。"
        extra={
          <Button icon={<ReloadOutlined />} onClick={() => query.refetch()}>
            刷新
          </Button>
        }
      />
      <Card className="section-card" title="上传原创视频">
        <Form layout="vertical">
          <Form.Item label="版权与来源" required>
            <Input.TextArea
              rows={2}
              maxLength={2000}
              value={rights}
              placeholder="例如：团队原创拍摄，已获得演员与音乐授权"
              onChange={(e) => setRights(e.target.value)}
            />
          </Form.Item>
          <Upload
            beforeUpload={upload}
            accept="video/mp4,video/webm,video/quicktime"
            showUploadList={false}
            disabled={uploading}
          >
            <Button
              type="primary"
              icon={<UploadOutlined />}
              loading={uploading}
            >
              选择视频并上传
            </Button>
          </Upload>
        </Form>
      </Card>
      <Card>
        <QueryState query={query}>
          <Table
            rowKey="asset_id"
            scroll={{ x: 900 }}
            dataSource={query.data?.items ?? []}
            columns={[
              { title: "文件", dataIndex: "filename" },
              {
                title: "状态",
                dataIndex: "status",
                render: (v) => (
                  <Tag
                    color={
                      v === "ready" ? "green" : v === "failed" ? "red" : "gold"
                    }
                  >
                    {statusNames[v] ?? v}
                  </Tag>
                ),
              },
              { title: "类型", dataIndex: "mime_type" },
              {
                title: "时长",
                dataIndex: "duration_ms",
                render: (v) => (v ? `${(v / 1000).toFixed(1)} 秒` : "—"),
              },
              { title: "版权来源", dataIndex: "rights_source", ellipsis: true },
              {
                title: "操作",
                render: (_, asset: Json) => (
                  <Space>
                    <Button
                      type="link"
                      disabled={asset.status !== "ready"}
                      onClick={async () => {
                        try {
                          setPreview({
                            ...asset,
                            ...(await api.request(
                              "GET",
                              `/v1/admin/assets/${asset.asset_id}/preview`,
                            )),
                          });
                        } catch (e) {
                          message.error((e as Error).message);
                        }
                      }}
                    >
                      首帧预览
                    </Button>
                    <Button
                      type="link"
                      disabled={asset.status !== "ready"}
                      onClick={() => {
                        setCaption(asset);
                        setVtt(
                          "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n请输入字幕。\n",
                        );
                      }}
                    >
                      添加字幕
                    </Button>
                  </Space>
                ),
              },
            ]}
          />
        </QueryState>
      </Card>
      <Modal
        title={preview?.filename}
        open={!!preview}
        onCancel={() => setPreview(null)}
        footer={null}
      >
        {preview && (
          <img
            className="asset-preview"
            src={preview.poster_url}
            alt={`${preview.filename} 首帧`}
          />
        )}
      </Modal>
      <Modal
        title="添加字幕版本"
        open={!!caption}
        onCancel={() => setCaption(null)}
        confirmLoading={busy}
        onOk={async () => {
          setBusy(true);
          try {
            await api.request(
              "POST",
              `/v1/admin/assets/${caption!.asset_id}/captions`,
              { ...command(), vtt },
            );
            setCaption(null);
            await query.refetch();
            message.success("已生成新字幕素材，请在内容工作室替换对应片段");
          } catch (e) {
            message.error((e as Error).message);
          } finally {
            setBusy(false);
          }
        }}
      >
        <Typography.Paragraph>
          保存会生成新素材，不会修改已经发布的版本。
        </Typography.Paragraph>
        <Input.TextArea
          aria-label="WebVTT 字幕"
          value={vtt}
          rows={12}
          maxLength={50000}
          onChange={(e) => setVtt(e.target.value)}
        />
      </Modal>
    </>
  );
}
