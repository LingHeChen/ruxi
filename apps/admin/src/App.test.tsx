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
  const router = mount("/editor/11111111-1111-4111-8111-111111111111");
  await screen.findByRole("button", { name: "登录工作台" });
  expect(router.state.location.pathname).toBe("/login");
  expect(
    new URLSearchParams(router.state.location.search).get("returnTo"),
  ).toBe("/editor/11111111-1111-4111-8111-111111111111");
});
it("blocks an editor account from reviewer pages", async () => {
  api.state = {
    ready: true,
    profile: { user_id: "editor", display_name: "编辑", roles: ["editor"] },
  };
  mount("/reports");
  await screen.findByText("暂无访问权限");
});
it("renders live-shaped story data and links to version workspace", async () => {
  api.state = {
    ready: true,
    profile: { user_id: "editor", display_name: "编辑", roles: ["editor"] },
  };
  vi.spyOn(api, "request").mockResolvedValue({
    items: [
      {
        story_id: "one",
        title: "末班车",
        summary: "悬疑故事",
        seat_count: 3,
        category: "mystery",
        current_version_id: null,
      },
    ],
  });
  mount("/stories");
  await screen.findByText("末班车");
  expect(screen.getByText("创建剧目")).toBeInTheDocument();
  await waitFor(() =>
    expect(api.request).toHaveBeenCalledWith("GET", "/v1/admin/stories"),
  );
});
