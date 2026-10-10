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
    action =
      if type == "action.submit",
        do: Enum.find(s["content"]["actions"], &(&1["id"] == body["action_id"]))

    npc =
      action &&
        Enum.any?(
          get_in(s, ["content", "c3_settings", "npcs"]) || [],
          &(&1["id"] == action["target"])
        )

    roles =
      if npc &&
           get_in(s, ["content", "c3_settings", "npc_interactions", action["id"], "execution"]) !=
             "round", do: [hd(Map.keys(s["actors"]))], else: Map.keys(s["actors"])

    next =
      Enum.reduce(roles, s, fn role, acc ->
        npc_action = Enum.find(acc["content"]["actions"], &(&1["id"] == body["action_id"]))

        npc =
          npc_action &&
            Enum.any?(acc["content"]["c3_settings"]["npcs"], &(&1["id"] == npc_action["target"]))

        if npc && get_in(acc, ["world", "done_" <> body["action_id"]]) do
          acc
        else
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

  def disclose_all(s) do
    s =
      if Enum.any?(s["actors"], fn {_, a} -> a["ap_remaining"] < 1 end),
        do: command(s, "round.end", %{}),
        else: s

    Enum.reduce(Map.keys(s["actors"]), s, fn role, acc ->
      {:ok, next, _} =
        Engine.command(
          acc,
          role,
          "action.submit",
          %{"action_id" => "disclose_" <> role, "step_id" => acc["step_id"]},
          Util.id(),
          1
        )

      next
    end)
    |> ack()
  end

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
               Enum.filter(
                 Engine.project(s, "reporter", 1)["self"]["objectives"],
                 &(&1["layer"] == "public")
               ),
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

    combinations =
      for mask <- 1..15,
          selected =
            for(
              {role, index} <- Enum.with_index(roles),
              Bitwise.band(mask, Bitwise.bsl(1, index)) != 0,
              do: role
            ),
          length(selected) >= 2,
          do: selected

    for selected <- combinations do
      count = length(selected)
      s = Engine.initial(story(), 0, active_roles: selected) |> ack()
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
        |> disclose_all()
        |> act("publish_truth")

      assert s["ending"] == "shore_names"

      for role <- selected do
        v = Engine.project(s, role, 1)
        assert Enum.any?(v["knowledge"], &(&1["id"] == "contact"))

        for other <- selected, other != role do
          refute Enum.any?(v["knowledge"], &(&1["id"] == "memory_" <> other <> "_2"))
          refute Enum.any?(v["narrative_cues"], &(&1["media_id"] == "memory_" <> other <> "_3"))
        end

        assert is_binary(v["room"]["ending"]["epilogue"])

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

  test "split investigations keep evidence local until explicitly shared" do
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

    # Talking to Chen is immediate and does not commit the reporter's queued inspection.
    assert s["intents"]["reporter"] != nil
    refute "clock" in s["actors"]["reporter"]["knowledge"]
    {:ok, s, _} = Engine.command(s, "archivist", "round.end", %{}, Util.id(), 1)
    s = ack(s)

    assert "clock" in s["actors"]["reporter"]["knowledge"]
    refute "chen_first" in s["actors"]["reporter"]["knowledge"]
    assert "chen_first" in s["actors"]["archivist"]["knowledge"]
    refute "clock" in s["actors"]["archivist"]["knowledge"]

    refute Enum.any?(
             Engine.project(s, "archivist", 1)["narrative_cues"],
             &(&1["media_id"] == "echo_inspect_clock")
           )

    {:ok, s, _} =
      Engine.command(
        s,
        "reporter",
        "knowledge.share",
        %{"clue_id" => "clock", "audience_member_ids" => ["archivist"]},
        Util.id(),
        1
      )

    assert "clock" in s["actors"]["archivist"]["knowledge"]
    refute "brief_reporter" in s["actors"]["archivist"]["knowledge"]
  end

  test "private character openings precede the public scene and only their readers must acknowledge them" do
    s = Engine.initial(story(), 0, active_roles: ~w(reporter archivist))

    for role <- ~w(reporter archivist) do
      v = Engine.project(s, role, 1)

      assert Enum.map(v["narrative_cues"], & &1["media_id"]) == [
               "role_opening_" <> role,
               "opening"
             ]

      other = if role == "reporter", do: "archivist", else: "reporter"
      refute Jason.encode!(v) =~ "role_opening_" <> other
    end

    private = Enum.find(s["cues"], &(&1["media_id"] == "role_opening_reporter"))

    assert {:error, "FORBIDDEN", _} =
             Engine.command(
               s,
               "archivist",
               "media.complete",
               %{"cue_id" => private["id"], "mode" => "summary"},
               Util.id(),
               1
             )

    assert s["phase"] == "presentation"
    s = ack(s)
    assert s["phase"] == "planning"
    assert s["barrier"] == nil
  end

  test "personal memories and disclosure choices stay role-owned and change each ending's epilogue" do
    for role <- ~w(reporter archivist volunteer photographer) do
      base = prepared(role) |> act("bypass_cabinet") |> solved()
      view = Engine.project(base, role, 1)
      assert Enum.any?(view["knowledge"], &(&1["id"] == "memory_" <> role <> "_2"))
      assert Enum.any?(view["knowledge"], &(&1["id"] == "memory_" <> role <> "_3"))
      assert Enum.any?(view["actions"], &(&1["id"] == "disclose_" <> role))

      refute Enum.any?(
               view["actions"],
               &(String.starts_with?(&1["id"], "disclose_") and &1["id"] != "disclose_" <> role)
             )

      disclosed = act(base, "disclose_" <> role)

      for choice <- ~w(publish_truth seal_handover accuse_murder leave_early) do
        # Leaving is offered at reception; the other decisions are made at the table.
        original = if choice == "leave_early", do: goto(base, "lobby"), else: base
        shared = if choice == "leave_early", do: goto(disclosed, "lobby"), else: disclosed
        original = act(original, choice) |> Engine.project(role, 1)
        shared = act(shared, choice) |> Engine.project(role, 1)
        assert original["room"]["ending"]["id"] == shared["room"]["ending"]["id"]
        refute original["room"]["ending"]["epilogue"] == shared["room"]["ending"]["epilogue"]
        personal = Enum.find(shared["self"]["objectives"], &(&1["id"] == "personal_" <> role))
        assert personal["result"] == "achieved"
      end
    end
  end

  test "explicit private media audiences are validated before play" do
    s = story()
    role = hd(s["roles"])
    ref = role["opening_media"]

    unsafe =
      Map.update!(s, "media", fn media ->
        Enum.map(media, fn m ->
          if m["id"] == ref, do: Map.put(m, "audience", "public"), else: m
        end)
      end)

    refute Content.validate(unsafe)["valid"]

    unsafe =
      Map.update!(s, "events", fn events ->
        [
          %{
            "id" => "leak",
            "trigger" => "step_end",
            "priority" => 0,
            "once" => true,
            "condition" => %{"op" => "all", "args" => []},
            "effects" => [
              %{"op" => "cue", "ref" => ref, "audience" => ["archivist"], "blocking" => true}
            ]
          }
          | events
        ]
      end)

    refute Content.validate(unsafe)["valid"]
  end
end
