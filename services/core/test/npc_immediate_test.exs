defmodule Ruxi.NpcImmediateTest do
  use ExUnit.Case, async: true
  alias Ruxi.C2.Engine
  alias Ruxi.Util

  defp initial do
    story =
      File.read!(Path.expand("../../../content/c3/tide_hotel/story.json", __DIR__))
      |> Jason.decode!()

    s = Engine.initial(story, 0, active_roles: ~w(reporter archivist volunteer))

    Enum.reduce(Map.keys(s["actors"]), s, fn r, s ->
      Enum.reduce(s["cues"], s, fn c, s ->
        if r in c["audience"] do
          {:ok, next, _} =
            Engine.command(
              s,
              r,
              "media.complete",
              %{"cue_id" => c["id"], "mode" => "summary"},
              Util.id(),
              1
            )

          next
        else
          s
        end
      end)
    end)
  end

  test "NPC reply, item ownership and receipt are immediate without settling a peer" do
    s = initial() |> put_in(["actors", "volunteer", "location"], "lounge")

    {:ok, s, _} =
      Engine.command(
        s,
        "archivist",
        "action.submit",
        %{"step_id" => s["step_id"], "action_id" => "read_receipt"},
        Util.id(),
        1
      )

    old = s
    id = Util.id()
    body = %{"step_id" => s["step_id"], "action_id" => "talk_lin"}
    {:ok, s, result} = Engine.command(s, "reporter", "action.submit", body, id, 1)
    assert result["status"] == "committed"

    assert s["actors"]["reporter"]["ap_remaining"] ==
             old["actors"]["reporter"]["ap_remaining"] - 1

    assert s["intents"] == old["intents"]
    assert s["step_id"] == old["step_id"]
    assert s["phase"] == "planning"
    assert s["ownership"]["key"]["owner"] == "reporter"
    view = Engine.project(s, "reporter", 1)
    assert Enum.any?(view["inventory"], &(&1["id"] == "key"))
    refute Enum.any?(view["knowledge"], &(&1["id"] == "key"))
    assert length(Engine.project(s, "archivist", 1)["scene_activity"]) == 1
    assert Engine.project(s, "volunteer", 1)["scene_activity"] == []
    cue = Enum.find(s["cues"], &(&1["media_id"] == "echo_talk_lin"))
    assert cue["audience"] == ["reporter"]
    refute cue["blocking"]
    {:ok, retry, _} = Engine.command(s, "reporter", "action.submit", body, id, 1)
    assert retry == s
  end

  test "Lin's handed-over documents are an inventory item while testimony remains knowledge" do
    s = initial()

    s =
      update_in(s, ["actors", "reporter", "knowledge"], &(~w(medical register letter wire) ++ &1))

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"step_id" => s["step_id"], "action_id" => "confront_lin"},
        Util.id(),
        1
      )

    v = Engine.project(s, "reporter", 1)

    assert Enum.any?(
             v["inventory"],
             &(&1["id"] == "lin_documents" and is_binary(&1["image_uri"]))
           )

    assert Enum.any?(v["knowledge"], &(&1["id"] == "lin_confess"))

    refute Enum.any?(
             Engine.project(s, "archivist", 1)["inventory"],
             &(&1["id"] == "lin_documents")
           )
  end

  test "scene witnesses receive clues without the discoverer's echo modal" do
    s = initial()

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"step_id" => s["step_id"], "action_id" => "read_receipt"},
        Util.id(),
        1
      )

    {:ok, s, _} = Engine.command(s, "archivist", "round.end", %{}, Util.id(), 1)
    {:ok, s, _} = Engine.command(s, "volunteer", "round.end", %{}, Util.id(), 1)
    witness = Engine.project(s, "archivist", 1)
    assert Enum.any?(witness["knowledge"], &(&1["id"] == "receipt"))
    refute Enum.any?(witness["narrative_cues"], &(&1["media_id"] == "echo_read_receipt"))
  end

  test "private NPC operations reveal neither notices nor dialogue nor clues to peers" do
    s = initial()

    s =
      put_in(s, ["content", "c3_settings", "npc_interactions"], %{
        "talk_lin" => %{"visibility" => "private"}
      })

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"step_id" => s["step_id"], "action_id" => "talk_lin"},
        Util.id(),
        1
      )

    peer = Engine.project(s, "archivist", 1)
    assert peer["scene_activity"] == []
    refute Enum.any?(peer["knowledge"], &(&1["id"] == "lin_first"))
    refute Enum.any?(peer["narrative_cues"], &(&1["media_id"] == "echo_talk_lin"))
  end
end
