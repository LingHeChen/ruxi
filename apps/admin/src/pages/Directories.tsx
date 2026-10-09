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
