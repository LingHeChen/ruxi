import { useEffect, useState, lazy, Suspense } from "react";
import {
  Navigate,
  Outlet,
  Route,
  Routes,
  useLocation,
  useNavigate,
  useParams,
} from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import {
  App,
  Avatar,
  Button,
  Card,
  Drawer,
  Flex,
  Form,
  Input,
  Layout,
  Menu,
  Result,
  Segmented,
  Spin,
  Typography,
} from "antd";
import {
  AppstoreOutlined,
  BookOutlined,
  EditOutlined,
  PictureOutlined,
  AuditOutlined,
  TeamOutlined,
  MenuOutlined,
  UserOutlined,
  LogoutOutlined,
} from "@ant-design/icons";
import { api, type Role } from "./api";
import { roleNames, useAuth } from "./shared";
import { Users } from "./pages/Directories";
import { Dashboard } from "./pages/Dashboard";

import { Releases } from "./pages/Releases";
import { Projects } from "./pages/Projects";
const World = lazy(() =>
  import("./pages/World").then((m) => ({ default: m.World })),
);
const sections = [
  { key: "/dashboard", label: "工作概览", icon: <AppstoreOutlined /> },
  {
    key: "/stories",
    label: "剧目管理",
    icon: <BookOutlined />,
    role: "editor",
  },
  {
    key: "/users",
    label: "用户管理",
    icon: <TeamOutlined />,
    role: "directory",
  },
];
function allowed(role: string | undefined, roles: Role[]) {
  return (
    !role ||
    (role === "directory"
      ? roles.includes("reviewer") || roles.includes("publisher")
      : roles.includes(role as Role))
  );
}
export function Guard({ role }: { role?: string }) {
  const { ready, profile } = useAuth();
  const location = useLocation();
  if (!ready)
    return (
      <div className="full-loading">
        <Spin size="large" />
      </div>
    );
  if (!profile)
    return (
      <Navigate
        to={`/login?returnTo=${encodeURIComponent(location.pathname + location.search)}`}
        replace
      />
    );
  if (!allowed(role, profile.roles))
    return (
      <Result
        status="403"
        title="暂无访问权限"
        subTitle="请联系具有发布管理权限的管理员。"
      />
    );
  return <Outlet />;
}
function Login() {
  const [useCode, setUseCode] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const navigate = useNavigate();
  const { profile } = useAuth();
  const location = useLocation();
  const desired =
    new URLSearchParams(location.search).get("returnTo") ?? "/dashboard";
  const destination =
    desired.startsWith("/") &&
    !desired.startsWith("//") &&
    !desired.startsWith("/login")
      ? desired
      : "/dashboard";
  if (profile) return <Navigate to={destination} replace />;
  return (
    <div className="login-page">
      <div className="login-brand">
        <div className="wordmark">入戏</div>
        <p>原创故事，从这里开始。</p>
        <Typography.Title>
          把故事里的每一种可能，
          <br />
          交给你的创作。
        </Typography.Title>
        <p>创作 · 预演 · 审核 · 发布</p>
      </div>
      <Card className="login-card">
        <Typography.Title level={3}>登录创作与运营中心</Typography.Title>
        <Typography.Paragraph type="secondary">
          使用管理员账号进入工作台
        </Typography.Paragraph>
        <Segmented
          block
          value={useCode ? "code" : "account"}
          onChange={(v) => {
            setUseCode(v === "code");
            setError("");
          }}
          options={[
            { value: "account", label: "账号密码" },
            { value: "code", label: "一次性登录码" },
          ]}
        />
        <Form
          key={String(useCode)}
          layout="vertical"
          onFinish={async (values) => {
            setBusy(true);
            setError("");
            try {
              await api.login(values, useCode);
              navigate(destination, { replace: true });
            } catch (e) {
              setError((e as Error).message);
            } finally {
              setBusy(false);
            }
          }}
        >
          {useCode ? (
            <Form.Item
              name="login_code"
              label="一次性登录码"
              rules={[{ required: true, message: "请输入登录码" }]}
            >
              <Input autoComplete="off" />
            </Form.Item>
          ) : (
            <>
              <Form.Item
                name="username"
                label="管理员账号"
                rules={[{ required: true, message: "请输入账号" }]}
              >
                <Input autoComplete="username" />
              </Form.Item>
              <Form.Item
                name="password"
                label="密码"
                rules={[{ required: true, message: "请输入密码" }]}
              >
                <Input.Password autoComplete="current-password" />
              </Form.Item>
            </>
          )}
          {error && (
            <Typography.Paragraph type="danger" role="alert">
              {error}
            </Typography.Paragraph>
          )}
          <Button
            htmlType="submit"
            type="primary"
            size="large"
            block
            loading={busy}
          >
            登录工作台
          </Button>
        </Form>
      </Card>
    </div>
  );
}
function StudioRedirect() {
  const { id, view } = useParams();
  return (
    <Navigate
      to={`/stories/${id}/${view === "releases" ? "releases" : "world"}`}
      replace
    />
  );
}
function Shell() {
  const { profile } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const query = useQueryClient();
  const { message } = App.useApp();
  const [mobile, setMobile] = useState(false),
    [narrow, setNarrow] = useState(false);
  const selected = location.pathname.startsWith("/studio")
    ? "/stories"
    : "/" + (location.pathname.split("/")[1] || "dashboard");
  const active = sections.find((s) => s.key === selected);
  const sidebar = (
    <>
      <div className="brand">
        <span>入戏</span>
        <small>创作与运营中心</small>
      </div>
      <Menu
        theme="dark"
        mode="inline"
        selectedKeys={[selected]}
        items={sections.filter((s) => allowed(s.role, profile!.roles))}
        onClick={(e) => {
          navigate(e.key);
          setMobile(false);
        }}
      />
      <div className="sidebar-footer">原创故事，从这里开始。</div>
    </>
  );
  return (
    <Layout className="app-layout">
      <Layout.Sider
        width={228}
        breakpoint="lg"
        collapsedWidth={0}
        onBreakpoint={setNarrow}
        trigger={null}
      >
        {sidebar}
      </Layout.Sider>
      <Drawer
        title="工作台导航"
        placement="left"
        open={mobile}
        onClose={() => setMobile(false)}
        styles={{ body: { padding: 0, background: "#19282c" } }}
      >
        {sidebar}
      </Drawer>
      <Layout>
        <Layout.Header className="header">
          <Flex align="center" gap={12}>
            {narrow && (
              <Button
                icon={<MenuOutlined />}
                aria-label="打开导航"
                onClick={() => setMobile(true)}
              />
            )}
            <Typography.Text type="secondary">
              工作台 / {active?.label ?? "剧目工作台"}
            </Typography.Text>
          </Flex>
          <Flex align="center" gap={12}>
            <Avatar icon={<UserOutlined />} />
            <span>{profile?.display_name}</span>
            <Button
              type="text"
              icon={<LogoutOutlined />}
              onClick={async () => {
                try {
                  await api.logout();
                } catch {
                  message.warning("会话已在本地退出");
                } finally {
                  query.clear();
                  navigate("/login", { replace: true });
                }
              }}
            >
              退出
            </Button>
          </Flex>
        </Layout.Header>
        <Layout.Content className="workspace">
          <Outlet />
        </Layout.Content>
      </Layout>
    </Layout>
  );
}
export function AdminApp() {
  const { profile } = useAuth();
  const query = useQueryClient();
  useEffect(() => {
    void api.bootstrap();
  }, []);
  useEffect(() => {
    if (!profile) query.clear();
  }, [profile, query]);
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route element={<Guard />}>
        <Route element={<Shell />}>
          <Route index element={<Navigate to="/dashboard" replace />} />
          <Route path="dashboard" element={<Dashboard />} />
          <Route element={<Guard role="editor" />}>
            <Route path="stories" element={<Projects />} />
            <Route path="stories/:id/releases" element={<Releases />} />
            <Route
              path="stories/:id/world"
              element={
                <Suspense fallback={<Spin />}>
                  <World />
                </Suspense>
              }
            />
            <Route
              path="studio/projects"
              element={<Navigate to="/stories" replace />}
            />
            <Route path="studio/:id/:view" element={<StudioRedirect />} />
            <Route
              path="editor/*"
              element={<Navigate to="/stories" replace />}
            />
            <Route path="assets" element={<Navigate to="/stories" replace />} />
          </Route>
          <Route element={<Guard role="directory" />}>
            <Route path="users" element={<Users />} />
          </Route>
          <Route
            path="*"
            element={
              <Result
                status="404"
                title="页面不存在"
                extra={<Button href="/dashboard">返回工作台</Button>}
              />
            }
          />
        </Route>
      </Route>
    </Routes>
  );
}
