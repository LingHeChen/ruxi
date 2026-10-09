defmodule Ruxi.TideHotelTest do
  use ExUnit.Case, async: true
  alias Ruxi.C2.{Content, Engine}
  alias Ruxi.C3.{Interactions, World}
  alias Ruxi.Util

  def story,
    do:
      File.read!(Path.expand("../../../content/c3/tide_hotel/story.json", __DIR__))
      |> Jason.decode!()

  def ack(s) do
    Enum.reduce(Map.keys(s["actors"]), s, fn role, acc ->
      Enum.reduce(acc["cues"], acc, fn c, current ->
        if role in c["audience"] and c["id"] not in (current["cue_acks"][role] || []) do
          {:ok, next, _} =
            Engine.command(
              current,
              role,
              "media.complete",
              %{"cue_id" => c["id"], "mode" => "summary"},
              Util.id(),
              1
            )

          next
        else
          current
        end
      end)
    end)
  end

  def command(s, type, body, read \\ true) do
    next =
      Enum.reduce(Map.keys(s["actors"]), s, fn role, acc ->
        case Engine.command(
               acc,
               role,
               type,
               Map.put(body, "step_id", acc["step_id"]),
               Util.id(),
               1
             ) do
          {:ok, next, _} -> next
          other -> flunk("#{type} #{inspect(body)}: #{inspect(other, limit: 4)}")
        end
      end)

    if read, do: ack(next), else: next
  end

  def act(s, id) do
    a = Enum.find(s["content"]["actions"], &(&1["id"] == id))
    cost = if a, do: a["cost"], else: 1

    s =
      if s["actors"][hd(Map.keys(s["actors"]))]["ap_remaining"] < cost,
        do: command(s, "round.end", %{}),
        else: s

    command(s, "action.submit", %{"action_id" => id, "target_id" => nil})
  end

  def goto(s, dest) do
    if s["actors"][hd(Map.keys(s["actors"]))]["location"] == dest,
      do: s,
      else:
        (
          links =
            World.links(s)
            |> Enum.filter(&World.traversable?(s, &1, hd(Map.keys(s["actors"])), 1))

          ids =
            path(
              links,
              [{s["actors"][hd(Map.keys(s["actors"]))]["location"], []}],
              MapSet.new(),
              dest
            )

          assert ids != nil, "No route to #{dest}"
          Enum.reduce(ids, s, fn id, acc -> act(acc, "move:" <> id) end)
        )
  end

  defp path(_, [], _, _), do: nil

  defp path(links, [{at, route} | rest], seen, dest) do
    cond do
      at == dest ->
        route

      MapSet.member?(seen, at) ->
        path(links, rest, seen, dest)

      true ->
        path(
          links,
          rest ++ for(l <- links, l["from"] == at, do: {l["to"], route ++ [l["id"]]}),
          MapSet.put(seen, at),
          dest
        )
    end
  end

  def route(s, loc, ids), do: Enum.reduce(ids, goto(s, loc), &act(&2, &1))

  def prepared(role \\ "reporter") do
    Engine.initial(story(), 0, active_roles: [role])
    |> ack()
    |> route("lobby", ~w(read_receipt talk_lin ask_lin_family))
    |> route("lounge", ~w(inspect_clock listen_window))
    |> route("corridor", ~w(inspect_tracks))
    |> route("room209", ~w(inspect_luggage play_tape))
    |> route("infirmary", ~w(talk_chen inspect_medicine ask_chen_oldcase ask_chen_call))
    |> route("generator", ~w(talk_zhao inspect_wire manual_log tell_zhao_medical))
    |> route("archive", ~w(read_register))
  end

  def solved(s),
    do:
      s
      |> route("archive", ~w(read_rescue read_unsent_letter copy_evidence))
      |> route("boathouse", ~w(talk_he inspect_rope ask_he_departure ask_he_rescue call_station))
      |> route("lobby", ~w(confront_lin))
      |> route("lounge", ~w(reconstruct))

  test "illustrated NPC content validates without unknown-scene or secret leakage" do
    content = story()
    assert Content.validate(content)["valid"]

    v =
      Engine.initial(content, 0, active_roles: ["reporter"])
      |> ack()
      |> Engine.project("reporter", 1)

    assert Enum.map(v["npcs"], & &1["id"]) == ["lin"]
    assert Enum.all?(v["map"]["locations"], & &1["image_uri"])
    refute Jason.encode!(v) =~ "scene_archive"
    refute Jason.encode!(v) =~ "cabinet_code"

    assert Enum.all?(content["actions"], fn a ->
             Enum.any?(
               content["media"],
               &(&1["id"] == "echo_" <> a["id"] and &1["kind"] == "image")
             )
           end)
  end

  test "three final choices and early departure have distinct endings" do
    base = prepared() |> act("bypass_cabinet") |> solved()
    assert base["round"] < 24

    for {choice, ending} <- [
          {"publish_truth", "shore_names"},
          {"seal_handover", "seven_days"},
          {"accuse_murder", "loud_error"}
        ] do
      s = act(base, choice)
      assert s["ending"] == ending

      assert Enum.all?(
               Engine.project(s, "reporter", 1)["self"]["objectives"],
               &(&1["result"] == "achieved")
             )
    end

    assert (Engine.initial(story(), 0, active_roles: ["reporter"])
            |> ack()
            |> act("leave_early"))["ending"] == "unanswered"
  end

  test "exhausted passwords keep guaranteed route and correct PIN opens cabinet" do
    base = prepared()

    for mode <- [:correct, :exhausted] do
      s =
        Enum.reduce(1..if(mode == :correct, do: 1, else: 6), base, fn _, acc ->
          acc =
            if acc["actors"]["reporter"]["ap_remaining"] == 0,
              do: command(acc, "round.end", %{}),
              else: acc

          {:ok, acc, q} = Interactions.quote(acc, "reporter", "cabinet_password", 1)

          command(acc, "interaction.submit", %{
            "quote_id" => q["quote_id"],
            "kind" => "password",
            "input" => %{"answer" => if(mode == :correct, do: "0921", else: "0000")}
          })
        end)

      s = if mode == :exhausted, do: act(s, "bypass_cabinet"), else: s
      assert s["world"]["cabinet_open"]
      assert (s |> solved() |> act("publish_truth"))["ending"] == "shore_names"
    end
  end

  test "optional repair failure and success allow same main route" do
    base = prepared() |> goto("generator")

    for target <- [0, 100] do
      s = put_in(base, ["content", "c3", "interactions", Access.at(1), "base_target"], target)
      {:ok, s, q} = Interactions.quote(s, "reporter", "repair_switchboard", 1)

      s =
        command(s, "interaction.submit", %{
          "quote_id" => q["quote_id"],
          "kind" => "check",
          "input" => %{}
        })

      assert s["world"]["power"] == (target == 100)

      assert (s
              |> goto("archive")
              |> act("bypass_cabinet")
              |> solved()
              |> act("publish_truth"))["ending"] == "shore_names"
    end
  end

  test "exhausted investigation budget uses incomplete ending" do
    s =
      Enum.reduce(1..24, Engine.initial(story(), 0, active_roles: ["reporter"]) |> ack(), fn _,
                                                                                             acc ->
        command(acc, "round.end", %{})
      end)

    assert s["ending"] == "storm_passed"
  end

  test "bundled image publication rejects arbitrary URLs and changed digests" do
    image = Enum.find(story()["media"], &(&1["id"] == "scene_lobby"))
    assert Ruxi.C3.Art.publishable?(image)
    refute Ruxi.C3.Art.publishable?(Map.put(image, "uri", "https://example.com/spoof.png"))
    refute Ruxi.C3.Art.publishable?(Map.put(image, "sha256", String.duplicate("0", 64)))
    refute Ruxi.C3.Art.publishable?(Map.delete(image, "sha256"))
  end

  test "two, three and four players complete the shared investigation with unanimous endings" do
    roles = ~w(reporter archivist volunteer photographer)

    for count <- 2..4 do
      s = Engine.initial(story(), 0, active_roles: Enum.take(roles, count)) |> ack()
      assert map_size(s["actors"]) == count

      s =
        s
        |> route("lobby", ~w(read_receipt talk_lin ask_lin_family))
        |> route("lounge", ~w(inspect_clock listen_window))
        |> route("corridor", ~w(inspect_tracks))
        |> route("room209", ~w(inspect_luggage play_tape))
        |> route("infirmary", ~w(talk_chen inspect_medicine ask_chen_oldcase ask_chen_call))
        |> route("generator", ~w(talk_zhao inspect_wire manual_log tell_zhao_medical))
        |> route("archive", ~w(read_register bypass_cabinet))
        |> solved()
        |> act("publish_truth")

      assert s["ending"] == "shore_names"

      for role <- Enum.take(roles, count) do
        v = Engine.project(s, role, 1)
        assert Enum.any?(v["knowledge"], &(&1["id"] == "contact"))
        assert Enum.all?(v["self"]["objectives"], &(&1["result"] == "achieved"))
      end

      assert Enum.count(s["cues"], &(&1["media_id"] == "echo_talk_lin")) == 1
    end
  end

  test "any of the four roles can play alone without absent actors or private brief leakage" do
    for role <- ~w(reporter archivist volunteer photographer) do
      s = Engine.initial(story(), 0, active_roles: [role]) |> ack()
      assert Map.keys(s["actors"]) == [role]
      v = Engine.project(s, role, 1)
      assert Enum.map(v["knowledge"], & &1["id"]) == ["brief_" <> role]

      assert (s |> command("action.submit", %{"action_id" => "leave_early"}))["ending"] ==
               "unanswered"

      assert (prepared(role)
              |> act("bypass_cabinet")
              |> solved()
              |> act("publish_truth"))["ending"] == "shore_names"
    end
  end

  test "one player cannot end another player's investigation without agreement" do
    s = Engine.initial(story(), 0, active_roles: ~w(reporter archivist)) |> ack()

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"action_id" => "leave_early", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    assert s["ending"] == nil

    {:ok, s, _} =
      Engine.command(
        s,
        "archivist",
        "action.submit",
        %{"action_id" => "talk_lin", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    assert s["ending"] == nil
    assert s["world"]["decision"] == ""
  end

  test "players can split between scenes and receive each other's main evidence" do
    s = Engine.initial(story(), 0, active_roles: ~w(reporter archivist)) |> ack()

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"action_id" => "move:lobby_lounge_ab", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    {:ok, s, _} =
      Engine.command(
        s,
        "archivist",
        "action.submit",
        %{"action_id" => "move:lobby_infirmary_ab", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    s = ack(s)
    assert s["actors"]["reporter"]["location"] == "lounge"
    assert s["actors"]["archivist"]["location"] == "infirmary"

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "action.submit",
        %{"action_id" => "inspect_clock", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    {:ok, s, _} =
      Engine.command(
        s,
        "archivist",
        "action.submit",
        %{"action_id" => "talk_chen", "step_id" => s["step_id"]},
        Util.id(),
        1
      )

    s = ack(s)

    for role <- ~w(reporter archivist) do
      assert "clock" in s["actors"][role]["knowledge"]
      assert "chen_first" in s["actors"][role]["knowledge"]
    end
  end
end
