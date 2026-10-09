import { beforeEach, afterEach, it, expect, vi } from "vitest";
import { render, screen, waitFor, cleanup } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App, ConfigProvider } from "antd";
import { AdminApp } from "./App";
import { api } from "./api";
beforeEach(() => {
  api.clear();
  vi.spyOn(api, "bootstrap").mockResolvedValue();
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
function mount(path: string) {
  const router = createMemoryRouter([{ path: "*", element: <AdminApp /> }], {
    initialEntries: [path],
  });
  render(
    <ConfigProvider>
      <App>
        <QueryClientProvider
          client={
            new QueryClient({ defaultOptions: { queries: { retry: false } } })
          }
        >
          <RouterProvider router={router} />
        </QueryClientProvider>
      </App>
    </ConfigProvider>,
  );
  return router;
}
it("preserves a deep editor address through the login redirect", async () => {
  const router = mount("/stories/11111111-1111-4111-8111-111111111111/world");
  await screen.findByRole("button", { name: "登录工作台" });
  expect(router.state.location.pathname).toBe("/login");
  expect(
    new URLSearchParams(router.state.location.search).get("returnTo"),
  ).toBe("/stories/11111111-1111-4111-8111-111111111111/world");
});
it("blocks an editor account from user administration", async () => {
  api.state = {
    ready: true,
    profile: { user_id: "editor", display_name: "编辑", roles: ["editor"] },
  };
  mount("/users");
  await screen.findByText("暂无访问权限");
});
it("renders only the unified new story catalogue", async () => {
  api.state = {
    ready: true,
    profile: { user_id: "editor", display_name: "编辑", roles: ["editor"] },
  };
  vi.spyOn(api, "c2").mockResolvedValue({
    items: [
      {
        id: "one",
        title: "末班车",
        summary: "悬疑故事",
        seat_count: 3,
        category: "mystery",
        current_release_id: null,
      },
    ],
  });
  mount("/stories");
  await screen.findByText("末班车");
  expect(screen.getByText("新建剧目")).toBeInTheDocument();
  expect(screen.queryByText("创作项目")).not.toBeInTheDocument();
  expect(screen.queryByText("内容工作室")).not.toBeInTheDocument();
  await waitFor(() => expect(api.c2).toHaveBeenCalledWith("GET", "/projects"));
});
