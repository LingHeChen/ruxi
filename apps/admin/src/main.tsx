import React from "react";
import ReactDOM from "react-dom/client";
import { createBrowserRouter, RouterProvider } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ConfigProvider, App as AntApp, Result, Button } from "antd";
import zhCN from "antd/locale/zh_CN";
import { AdminApp } from "./App";
import "antd/dist/reset.css";
import "@xyflow/react/dist/style.css";
import "./style.css";
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 15000, refetchOnWindowFocus: false },
  },
});
const router = createBrowserRouter([
  {
    path: "*",
    element: <AdminApp />,
    errorElement: (
      <Result
        status="500"
        title="页面加载失败"
        subTitle="请重新加载页面；若问题持续，请联系管理员。"
        extra={
          <Button onClick={() => window.location.reload()}>重新加载</Button>
        }
      />
    ),
  },
]);
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ConfigProvider
      locale={zhCN}
      theme={{
        token: {
          colorPrimary: "#397858",
          borderRadius: 10,
          fontFamily: '"PingFang SC", "Microsoft YaHei", sans-serif',
          colorBgLayout: "#f5f7f5",
        },
        components: {
          Menu: {
            darkItemBg: "#17392e",
            darkItemSelectedBg: "#2d5140",
            darkItemSelectedColor: "#e0ecd9",
          },
          Layout: { siderBg: "#17392e", headerBg: "#fff" },
        },
      }}
    >
      <AntApp>
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </AntApp>
    </ConfigProvider>
  </React.StrictMode>,
);
