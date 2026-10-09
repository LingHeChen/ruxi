import { beforeEach, afterEach, it, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  waitFor,
  cleanup,
} from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App } from "antd";
import { api } from "../api";
import { Editor } from "./Editor";
import demo from "../../../../content/demo/story.json";
vi.mock("@xyflow/react", async () => {
  const awaitReact = await import("react");
  return {
    useNodesState: (initial: any) => {
      const { useState } = awaitReact;
      const [nodes, setNodes] = useState(initial);
      return [nodes, setNodes, () => {}];
    },
    ReactFlow: () => <div>画布</div>,
    Background: () => null,
    Controls: () => null,
    MiniMap: () => null,
    Handle: () => null,
    Position: { Left: "left", Right: "right" },
  };
});
beforeEach(() => {
  api.clear();
  api.state = {
    ready: true,
    profile: {
      user_id: "editor",
      display_name: "编辑",
      roles: ["editor", "reviewer", "publisher"],
    },
  };
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
it("keeps unsaved edits out of server validation and saves the loaded revision", async () => {
  let version = {
    version_id: "v1",
    revision: 7,
    graph: structuredClone(demo),
    status: "draft",
    hash: "fingerprint",
  };
  const request = vi
    .spyOn(api, "request")
    .mockImplementation(async (method, path, body) => {
      if (path === "/v1/admin/assets") return { items: [] };
      if (method === "PUT") {
        expect(body?.revision).toBe(7);
        version = { ...version, revision: 8, graph: body?.graph };
        return { revision: 8 };
      }
      return version;
    });
  const router = createMemoryRouter(
    [{ path: "/editor/:versionId", element: <Editor /> }],
    { initialEntries: ["/editor/v1"] },
  );
  render(
    <App>
      <QueryClientProvider
        client={
          new QueryClient({ defaultOptions: { queries: { retry: false } } })
        }
      >
        <RouterProvider router={router} />
      </QueryClientProvider>
    </App>,
  );
  await screen.findByText(demo.title);
  fireEvent.click(screen.getByRole("tab", { name: "完整内容编辑" }));
  fireEvent.click(screen.getByText("剧目名称"));
  const input = screen.getByRole("textbox");
  fireEvent.change(input, { target: { value: "新的故事标题" } });
  expect(screen.getByText("未保存")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("tab", { name: "校验与发布" }));
  expect(screen.getByRole("button", { name: "校验内容" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "保存草稿" }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith(
      "PUT",
      "/v1/admin/versions/v1",
      expect.objectContaining({
        revision: 7,
        graph: expect.objectContaining({ title: "新的故事标题" }),
      }),
    ),
  );
  await waitFor(() =>
    expect(screen.queryByText("未保存")).not.toBeInTheDocument(),
  );
});
