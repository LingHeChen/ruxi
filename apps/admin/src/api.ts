export type Json = Record<string, any>;
export type Role = "editor" | "reviewer" | "publisher";
export interface Profile {
  user_id: string;
  display_name: string;
  roles: Role[];
}
export interface AuthState {
  ready: boolean;
  profile: Profile | null;
}
const labels: Record<string, string> = {
  UNAUTHORIZED: "登录已过期或账号密码不正确，请重新登录",
  AUTH_EXPIRED: "登录已过期，请重新登录",
  NOT_ALLOWED: "当前账号没有操作权限",
  REVISION_CONFLICT: "草稿已被其他操作修改，请重新读取后合并修改",
  RESOURCE_NOT_FOUND: "内容不存在或当前账号无权访问",
  CONTENT_INVALID: "内容未通过校验，请查看验证报告",
  ASSET_NOT_READY: "素材尚未就绪",
  HASH_CHANGED: "内容已修改，请重新审核",
  RATE_LIMITED: "操作过于频繁，请稍后重试",
  USERNAME_TAKEN: "账号已存在",
  RIGHTS_REQUIRED: "请填写版权来源",
  INVALID_ARGUMENT: "输入不符合接口要求，请检查表单",
  INVALID_CAPTIONS: "字幕格式或时间范围不正确",
};
export class ApiError extends Error {
  constructor(
    public code: string,
    public status = 0,
  ) {
    super(labels[code] ?? `操作失败 · ${code}`);
  }
}
export const command = () => ({ command_id: crypto.randomUUID() });
export class ApiClient {
  state: AuthState = { ready: false, profile: null };
  listeners = new Set<() => void>();
  device = sessionStorage.getItem("ruxi.creator.device") ?? crypto.randomUUID();
  private access = sessionStorage.getItem("ruxi.creator.access") ?? "";
  private refreshToken = sessionStorage.getItem("ruxi.creator.refresh") ?? "";
  private refreshing?: Promise<void>;
  private bootstrapping?: Promise<void>;
  private epoch = 0;
  base = (import.meta.env.VITE_API_BASE ?? "http://localhost:4000").replace(
    /\/$/,
    "",
  );
  constructor() {
    sessionStorage.setItem("ruxi.creator.device", this.device);
  }
  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  };
  snapshot = () => this.state;
  private emit(state: AuthState) {
    this.state = state;
    this.listeners.forEach((fn) => fn());
  }
  private store(data: Json) {
    this.access = data.access_token;
    this.refreshToken = data.refresh_token;
    sessionStorage.setItem("ruxi.creator.access", this.access);
    sessionStorage.setItem("ruxi.creator.refresh", this.refreshToken);
  }
  clear() {
    this.epoch++;
    this.access = this.refreshToken = "";
    sessionStorage.removeItem("ruxi.creator.access");
    sessionStorage.removeItem("ruxi.creator.refresh");
    this.emit({ ready: true, profile: null });
  }
  async request<T = Json>(
    method: string,
    path: string,
    body?: Json,
    retried = false,
    extraHeaders: Record<string, string> = {},
  ): Promise<T> {
    const response = await fetch(this.base + path, {
      method,
      headers: {
        "Content-Type": "application/json",
        ...(this.access ? { Authorization: `Bearer ${this.access}` } : {}),
        ...extraHeaders,
      },
      body: method === "GET" ? undefined : JSON.stringify(body ?? {}),
      signal: AbortSignal.timeout(15000),
    });
    const data = await response.json();
    if (
      response.status === 401 &&
      !retried &&
      this.refreshToken &&
      !path.includes("/auth/")
    ) {
      try {
        await this.refresh();
      } catch (error) {
        this.clear();
        throw error;
      }
      return this.request<T>(method, path, body, true, extraHeaders);
    }
    if (!response.ok) {
      if (response.status === 401 && !path.includes("/auth/")) this.clear();
      throw new ApiError(
        data.error?.code ?? "SERVICE_UNAVAILABLE",
        response.status,
      );
    }
    return data.data as T;
  }
  c2<T = Json>(
    method: string,
    path: string,
    body?: Json,
    revision?: number,
  ): Promise<T> {
    const route = path.startsWith("/projects")
      ? `/studio${path}`
      : path.startsWith("/releases")
        ? `/admin${path}`
        : path;
    return this.request<T>(method, `/api/v2${route}`, body, false, {
      ...(method === "GET" ? {} : { "Idempotency-Key": crypto.randomUUID() }),
      ...(revision === undefined ? {} : { "If-Match": String(revision) }),
    });
  }
  private refresh() {
    return (this.refreshing ??= (async () => {
      const epoch = this.epoch;
      const data = await this.request("POST", "/v1/admin/auth/refresh", {
        refresh_token: this.refreshToken,
        device_id: this.device,
        refresh_request_id: crypto.randomUUID(),
      });
      if (epoch !== this.epoch) throw new ApiError("AUTH_EXPIRED");
      this.store(data);
    })().finally(() => {
      this.refreshing = undefined;
    }));
  }
  bootstrap() {
    return (this.bootstrapping ??= (async () => {
      if (!this.access) {
        this.emit({ ready: true, profile: null });
        return;
      }
      const epoch = this.epoch;
      try {
        const profile = await this.request<Profile>("GET", "/v1/admin/me");
        if (epoch !== this.epoch) return;
        this.emit({ ready: true, profile });
      } catch {
        this.clear();
      }
    })());
  }
  async login(values: Json, useCode = false) {
    const data = await this.request(
      "POST",
      useCode ? "/v1/admin/auth/exchange" : "/v1/admin/auth/login",
      {
        ...values,
        device_id: this.device,
        login_request_id: crypto.randomUUID(),
      },
    );
    this.epoch++;
    this.store(data);
    const epoch = this.epoch;
    try {
      const profile = await this.request<Profile>("GET", "/v1/admin/me");
      if (epoch !== this.epoch) throw new ApiError("AUTH_EXPIRED");
      this.emit({ ready: true, profile });
    } catch (error) {
      this.clear();
      throw error;
    }
  }
  async logout() {
    try {
      await this.request("POST", "/v1/admin/auth/logout");
    } finally {
      this.clear();
    }
  }
}
export const api = new ApiClient();
