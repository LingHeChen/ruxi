import { useSyncExternalStore } from "react";
import { Alert, Button, Card, Skeleton, Typography } from "antd";
import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
export const categories = [
  { value: "mystery", label: "悬疑推理" },
  { value: "emotion", label: "情感沉浸" },
  { value: "scifi", label: "科幻想象" },
  { value: "adventure", label: "冒险探索" },
];
export const difficulties = [
  { value: "beginner", label: "新手友好" },
  { value: "intermediate", label: "进阶挑战" },
  { value: "advanced", label: "深度推理" },
];
export const roleNames: Record<string, string> = {
  editor: "内容编辑",
  reviewer: "审核人员",
  publisher: "发布管理",
};
export const statusNames: Record<string, string> = {
  draft: "草稿",
  approved: "已审核",
  published: "已发布",
  ready: "已就绪",
  processing: "处理中",
  queued: "排队中",
  leased: "处理中",
  completed: "已完成",
  failed: "失败",
  lobby: "等待开场",
  running: "进行中",
  paused: "暂停",
  suspended: "等待重连",
  finished: "已完成",
  abandoned: "已结束",
  briefing: "共同开场",
  exploration: "探索",
  interlude: "中场",
  decision: "决策",
  ending: "结局",
  player_hint: "玩家提示",
  editor_proposal: "制作建议",
  media_transcode: "素材转码",
};
export const useAuth = () => useSyncExternalStore(api.subscribe, api.snapshot);
export function useApi<T = any>(
  path: string,
  enabled = true,
  interval?: number | false,
) {
  const { profile } = useAuth();
  return useQuery<T>({
    queryKey: [profile?.user_id, path],
    queryFn: () => api.request<T>("GET", path),
    enabled: enabled && !!profile,
    retry: 1,
    refetchInterval: interval,
  });
}
export function QueryState({
  query,
  children,
}: {
  query: any;
  children: React.ReactNode;
}) {
  if (query.isPending)
    return (
      <Card>
        <Skeleton active />
      </Card>
    );
  if (query.isError)
    return (
      <Alert
        type="error"
        showIcon
        title="读取失败"
        description={query.error.message}
        action={<Button onClick={() => query.refetch()}>重试</Button>}
      />
    );
  return children;
}
export function PageTitle({
  title,
  description,
  extra,
}: {
  title: string;
  description: string;
  extra?: React.ReactNode;
}) {
  return (
    <div className="page-title">
      <div>
        <Typography.Title level={2}>{title}</Typography.Title>
        <Typography.Text type="secondary">{description}</Typography.Text>
      </div>
      <div>{extra}</div>
    </div>
  );
}
export function JsonView({ value }: { value: any }) {
  return <pre className="json-view">{JSON.stringify(value, null, 2)}</pre>;
}
