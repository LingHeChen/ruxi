import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App } from "antd";
import { api, ApiError } from "../api";
import { World } from "./World";
import story from "../../../../content/c2/restaurant.json";
vi.mock("@xyflow/react", () => ({
  ReactFlow: ({ nodes, edges, onNodeClick }: any) => (
    <div>
      {nodes.map((n: any) => (
        <button key={n.id} onClick={() => onNodeClick({}, n)}>
          {n.data.label}
        </button>
      ))}
      {edges.map((e: any) => (
        <span key={e.id}>{e.label}</span>
      ))}
    </div>
  ),
  Background: () => null,
  Controls: () => null,
  MiniMap: () => null,
  Handle: () => null,
  Position: { Left: "left", Right: "right" },
}));
beforeEach(() => {
  localStorage.clear();
  api.state = {
    ready: true,
    profile: { user_id: "writer", display_name: "作者", roles: ["editor"] },
  };
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
function mount() {
  const q = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <App>
      <QueryClientProvider client={q}>
        <RouterProvider
          router={createMemoryRouter(
            [{ path: "/studio/:id/world", element: <World /> }],
            { initialEntries: ["/studio/project/world"] },
          )}
        />
      </QueryClientProvider>
    </App>,
  );
}
function responses(conflict = false) {
  return vi.spyOn(api, "c2").mockImplementation(async (method, path, body) => {
    if (method === "GET" && path.endsWith("draft"))
      return { content: structuredClone(story), revision: 4 } as any;
    if (method === "GET")
      return { layout: { positions: {} }, layout_revision: 2 } as any;
    if (conflict) throw new ApiError("REVISION_CONFLICT", 412);
    return { revision: 5, content: body?.content } as any;
  });
}
it("renders actual location containers, actions and directed links", async () => {
  responses();
  mount();
  expect(
    await screen.findByText("检查餐具 / 1 点", { exact: false }),
  ).toBeInTheDocument();
  expect(screen.getAllByText("通路 · 1 点")).toHaveLength(4);
  fireEvent.click(screen.getByRole("button", { name: "对象 · 餐具" }));
  expect(
    await screen.findByText("对象 · 餐具", { selector: ".ant-drawer-title" }),
  ).toBeInTheDocument();
});
it("keeps local content and stops overwriting after an optimistic revision conflict", async () => {
  const call = responses(true);
  mount();
  await screen.findByText("停电之前");
  fireEvent.click(screen.getByRole("button", { name: "回合与行动点规则" }));
  const input = await screen.findByRole("spinbutton", {
    name: "每回合行动点",
    hidden: false,
  });
  fireEvent.change(input, { target: { value: "4" } });
  fireEvent.click(screen.getByRole("button", { name: "立即保存" }));
  await waitFor(() =>
    expect(
      screen.getByText("服务器版本已变化，本地修改已保留"),
    ).toBeInTheDocument(),
  );
  expect(localStorage.getItem("ruxi.c2.draft:writer:project")).toContain(
    '"ap_per_round":4',
  );
  expect(call.mock.calls.find((c) => c[0] === "PUT")?.[3]).toBe(4);
});
