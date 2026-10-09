import { Button, Card, Flex, Statistic, Typography } from "antd";
import { useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { api, type Json } from "../api";
import { PageTitle, useAuth } from "../shared";
export function Dashboard() {
  const { profile } = useAuth();
  const navigate = useNavigate();
  const query = useQuery({
    queryKey: ["c2-projects"],
    queryFn: () => api.c2("GET", "/projects"),
    enabled: profile?.roles.includes("editor"),
  });
  const items: Json[] = query.data?.items ?? [];
  return (
    <>
      <PageTitle
        title={`你好，${profile?.display_name ?? "创作者"}`}
        description="今天，让故事再向前一步。"
      />
      <div className="dashboard-hero">
        <span className="eyebrow">RUXI · CREATOR WORKSPACE</span>
        <h1>
          让你的故事，
          <br />
          拥有更多可能。
        </h1>
        <p>创作世界，编排行动，和朋友一起探索每一种结局。</p>
        {profile?.roles.includes("editor") && (
          <Button
            size="large"
            type="primary"
            onClick={() => navigate("/stories")}
          >
            开始创作 →
          </Button>
        )}
        <div className="dashboard-art" aria-hidden="true">
          入戏
        </div>
      </div>
      <div className="stat-grid">
        {[
          ["全部剧目", items.length],
          [
            "创作中",
            items.filter((p) => !p.current_release_id && !p.archived_at).length,
          ],
          [
            "已发布",
            items.filter((p) => p.current_release_id && !p.archived_at).length,
          ],
          ["已归档", items.filter((p) => p.archived_at).length],
        ].map(([title, value]) => (
          <Card key={String(title)}>
            <Statistic title={title} value={value} />
          </Card>
        ))}
      </div>
      <Card
        title="最近创作"
        extra={
          <Button type="link" onClick={() => navigate("/stories")}>
            查看全部 →
          </Button>
        }
      >
        {items.slice(0, 5).map((p) => (
          <Flex
            key={p.id}
            className="recent-story"
            align="center"
            justify="space-between"
          >
            <div>
              <Typography.Text strong>{p.title}</Typography.Text>
              <div className="secondary">
                {p.summary || "继续构建你的故事世界"}
              </div>
            </div>
            <Button onClick={() => navigate(`/stories/${p.id}/world`)}>
              继续创作
            </Button>
          </Flex>
        ))}
        {!items.length && (
          <Typography.Text type="secondary">
            创作完成后，你的剧目会出现在这里。
          </Typography.Text>
        )}
      </Card>
    </>
  );
}
