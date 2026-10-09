import { beforeEach, afterEach, describe, it, expect, vi } from "vitest";
import { ApiClient } from "./api";
const response = (data: any, status = 200) =>
  new Response(
    JSON.stringify(
      status === 200 ? { data } : { error: { code: "AUTH_EXPIRED" } },
    ),
    { status, headers: { "Content-Type": "application/json" } },
  );
beforeEach(() => {
  sessionStorage.clear();
});
afterEach(() => vi.unstubAllGlobals());
describe("admin authentication", () => {
  it("does not bootstrap an absent session with a network call", async () => {
    const fetcher = vi.fn();
    vi.stubGlobal("fetch", fetcher);
    const client = new ApiClient();
    await client.bootstrap();
    expect(client.snapshot()).toEqual({ ready: true, profile: null });
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("coalesces refresh when concurrent reads expire", async () => {
    sessionStorage.setItem("ruxi.creator.access", "old");
    sessionStorage.setItem("ruxi.creator.refresh", "refresh");
    let refreshes = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init: RequestInit) => {
        if (url.endsWith("/auth/refresh")) {
          refreshes++;
          await new Promise((resolve) => setTimeout(resolve, 10));
          return response({ access_token: "new", refresh_token: "rotated" });
        }
        return (init.headers as any).Authorization === "Bearer new"
          ? response({ ok: true })
          : response(null, 401);
      }),
    );
    const client = new ApiClient();
    const results = await Promise.all([
      client.request("GET", "/one"),
      client.request("GET", "/two"),
    ]);
    expect(results).toEqual([{ ok: true }, { ok: true }]);
    expect(refreshes).toBe(1);
  });
  it("cannot restore tokens after logout races a refresh", async () => {
    sessionStorage.setItem("ruxi.creator.access", "old");
    sessionStorage.setItem("ruxi.creator.refresh", "refresh");
    let resolveRefresh!: (r: Response) => void;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) =>
        url.endsWith("/auth/refresh")
          ? await new Promise<Response>((resolve) => {
              resolveRefresh = resolve;
            })
          : response(null, 401),
      ),
    );
    const client = new ApiClient();
    const pending = client.request("GET", "/one");
    const assertion = expect(pending).rejects.toThrow();
    await vi.waitFor(() => expect(resolveRefresh).toBeDefined());
    client.clear();
    resolveRefresh(
      response({ access_token: "new", refresh_token: "new-refresh" }),
    );
    await assertion;
    expect(sessionStorage.getItem("ruxi.creator.access")).toBeNull();
    expect(client.snapshot().profile).toBeNull();
  });
  it("clears rejected refresh credentials", async () => {
    sessionStorage.setItem("ruxi.creator.access", "old");
    sessionStorage.setItem("ruxi.creator.refresh", "refresh");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => response(null, 401)),
    );
    const client = new ApiClient();
    await expect(client.request("GET", "/one")).rejects.toThrow();
    expect(sessionStorage.getItem("ruxi.creator.refresh")).toBeNull();
  });
});
