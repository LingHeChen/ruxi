defmodule Ruxi.Content do
  alias Ruxi.{DB, Util}
  @story "11111111-1111-4111-8111-111111111111"
  @version "11111111-1111-4111-8111-333333333333"
  @media ~w(opening role_investigator role_passenger role_conductor interlude ending_E1 ending_E2 ending_E3)
  def story_id, do: @story
  def version_id, do: @version
  def media_codes, do: @media

  def graph(s), do: s["content"] || demo_graph()

  def role_definitions(s) do
    g = graph(s)

    Map.new(g["roles"], fn code ->
      {title, description} = Ruxi.Rules.roles()[code] || {code, "按你的角色参与故事。"}

      {code,
       (g["role_definitions"] || %{})[code] || %{"title" => title, "description" => description}}
    end)
  end

  def asset_id(s, code) do
    case Enum.find(graph(s)["assets"] || [], &(&1["media_id"] == code)) do
      nil -> asset_id(code)
      a -> a["asset_id"]
    end
  end

  def abstract(s) do
    roles = Map.new(s["members"], &{&1["id"], &1["role"]})
    known = Map.new(s["members"], &{&1["role"], &1["known"]})

    done =
      s["done"] ||
        graph(s)["actions"]
        |> Enum.filter(fn a ->
          Enum.all?(a["effects"], fn e ->
            (e["grant_clue"] || e["grant_item"]) in (known[a["role"]] || [])
          end)
        end)
        |> Enum.map(& &1["id"])

    %{
      "known" => known,
      "shared" => s["shared"],
      "items" => Map.new(s["items"], fn {code, item} -> {code, roles[item["owner"]]} end),
      "vars" => s["vars"] || Ruxi.ContentAST.initial_vars(graph(s)),
      "done" => done
    }
  end

  def actions(s, role), do: Enum.filter(graph(s)["actions"], &(&1["role"] == role))

  def action_label(a),
    do:
      a["label"] ||
        %{"inspect_monitor" => "调查监控", "inspect_phone" => "调查手机", "open_cabinet" => "解锁控制柜"}[
          a["id"]
        ] || a["id"]

  def option_label(s, code),
    do:
      (graph(s)["option_labels"] || %{})[code] ||
        %{"leave" => "离开列车", "wait" => "继续等待", "publish" => "公开异常"}[code] || code

  def asset_id(code),
    do:
      "aaaaaaaa-aaaa-4aaa-8aaa-" <>
        String.pad_leading(Integer.to_string(Enum.find_index(@media, &(&1 == code)) + 1), 12, "0")

  def summary(code, role) do
    case code do
      "opening" -> "末班车即将离站。一段未来留言要求你们检查车上的异常装置。先各自了解角色，再讨论调查结果。"
      "role_" <> _ -> elem(Ruxi.Rules.roles()[role], 1)
      "interlude" -> "警报响起，车门即将关闭。探索已经结束，请一起决定离开、等待，或公开你们掌握的证据。"
      "ending_E1" -> "真相：你们公开了关键证据，异常装置的秘密终于被揭开。"
      "ending_E2" -> "错过：你们选择继续等待。第七位乘客始终没有出现。"
      "ending_E3" -> "余音：你们离开了列车。车厢里的声音还在。"
    end
  end

  def seed do
    graph =
      File.read!(Path.expand("../../content/demo/story.json", File.cwd!())) |> Jason.decode!()

    DB.query(
      "INSERT INTO stories(id,title,summary,seat_count) VALUES($1,$2,$3,3) ON CONFLICT DO NOTHING",
      [DB.uuid(@story), graph["title"], "三人各自掌握一段秘密，共同决定末班车的命运。"]
    )

    DB.query(
      "INSERT INTO content_versions(id,story_id,graph,content_hash,status,published_at) VALUES($1,$2,$3,$4,'published',$5) ON CONFLICT DO NOTHING",
      [DB.uuid(@version), DB.uuid(@story), graph, Util.hash(graph), Util.now()]
    )

    DB.query("UPDATE stories SET current_version_id=$1 WHERE id=$2", [
      DB.uuid(@version),
      DB.uuid(@story)
    ])
  end

  def validate(g) do
    Ruxi.ContentAST.compile(g)
    |> Map.put("assets_ready", Ruxi.Media.ready?(g))
    |> Map.put(
      "note",
      "Media rights and multi-role playtest must be reviewed before publication."
    )
  end

  def demo_graph,
    do: File.read!(Path.expand("../../content/demo/story.json", File.cwd!())) |> Jason.decode!()
end
