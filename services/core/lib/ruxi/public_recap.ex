defmodule Ruxi.PublicRecap do
  @moduledoc "Public committed milestones only: no private discoveries, votes, transfers, hints or chat."
  alias Ruxi.{Content, ContentAST, DB, Util}

  def advance(old, new, now) do
    phases =
      if old["phase"] != new["phase"] and new["phase"] != nil do
        label =
          case new["phase"] do
            "briefing" -> "故事开场"
            "exploration" -> "进入角色探索"
            "decision" -> "开始共同抉择"
            "ending" -> "结局已确定：#{new["ending"]}"
          end

        [{"phase", label}]
      else
        []
      end

    lifecycle =
      if old["lifecycle"] != new["lifecycle"] do
        label =
          %{
            "running" => "房间开始或恢复",
            "paused" => "房间已暂停",
            "suspended" => "房间已挂起",
            "finished" => "本局故事完成",
            "abandoned" => "房间已结束"
          }[new["lifecycle"]]

        if label, do: [{"lifecycle", label}], else: []
      else
        []
      end

    shared =
      for id <- new["shared"] -- old["shared"] do
        clue = ContentAST.clues(Content.graph(new))[id]
        {"shared_clue", "公开线索：#{clue["title"]}"}
      end

    milestones = phases ++ lifecycle ++ shared

    if milestones == [] do
      Map.put_new(new, "public_timeline", old["public_timeline"] || [])
    else
      rid = DB.uuid(new["room_id"])

      base =
        DB.one("SELECT COALESCE(max(seq),0) AS seq FROM room_public_events WHERE room_id=$1", [
          rid
        ])["seq"]

      events =
        for {{kind, label}, index} <- Enum.with_index(milestones, 1) do
          seq = base + index

          DB.query(
            "INSERT INTO room_public_events(room_id,seq,kind,label,occurred_at) VALUES($1,$2,$3,$4,$5)",
            [rid, seq, kind, label, now]
          )

          %{"seq" => seq, "kind" => kind, "label" => label, "occurred_at" => Util.iso(now)}
        end

      Map.put(new, "public_timeline", Enum.take((old["public_timeline"] || []) ++ events, -200))
    end
  end

  def restore(rid) do
    DB.rows(
      "SELECT seq,kind,label,occurred_at FROM room_public_events WHERE room_id=$1 ORDER BY seq DESC LIMIT 200",
      [rid]
    )
    |> Enum.reverse()
    |> Enum.map(&Map.update!(&1, "occurred_at", fn time -> Util.iso(time) end))
  end
end
