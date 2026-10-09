defmodule Ruxi.C2EngineTest do
  use ExUnit.Case, async: true
  alias Ruxi.C2.{Engine, Content, Schema}

  defp fixture(name),
    do: File.read!(Path.expand("../../../content/c2/#{name}.json", __DIR__)) |> Jason.decode!()

  defp story, do: fixture("restaurant")

  defp initial(s \\ story()) do
    e = Engine.initial(s, 0, random_key: :binary.copy(<<7>>, 32))

    Enum.reduce(s["roles"], e, fn r, acc ->
      Enum.reduce(acc["cues"], acc, fn c, next ->
        {:ok, next, _} =
          Engine.command(
            next,
            r["id"],
            "media.complete",
            %{"cue_id" => c["id"], "mode" => "summary"},
            Ruxi.Util.id(),
            1
          )

        next
      end)
    end)
  end

  defp cmd(e, role, type, body, now \\ 2),
    do: Engine.command(e, role, type, body, Ruxi.Util.id(), now)

  defp submit(e, role, id, now \\ 2),
    do: cmd(e, role, "action.submit", %{"action_id" => id, "step_id" => e["step_id"]}, now)

  defp step(e, actions) do
    old_id = e["step_id"]

    e =
      Enum.reduce(actions, e, fn {r, a}, next ->
        {:ok, next, _} = submit(next, r, a)
        next
      end)

    if e["step_id"] == old_id and e["status"] == "active",
      do:
        (case Engine.resolve(e, 3) do
           {:ok, next} -> next
         end),
      else: e
  end

  test "canonical C2 schema and invalid design fixtures are enforced" do
    assert Content.validate(story())["valid"]

    for name <- ~w(invalid_bad_cost invalid_missing_location invalid_unknown_ref) do
      report = Content.validate(fixture(name))
      refute report["valid"], name
      assert Enum.all?(report["errors"], &is_binary(&1["pointer"]))
    end

    assert Schema.validate(Map.put(story(), "editor_layout", %{}), Schema.load("story")) != []
  end

  test "global actor access, private media broadcast and variable type changes are rejected" do
    s = story()
    event = hd(s["events"])

    event =
      Map.put(event, "condition", %{"op" => "eq", "ref" => "actor.location", "value" => "kitchen"})

    assert Enum.any?(
             Content.validate(Map.put(s, "events", [event | tl(s["events"])]))["errors"],
             &(&1["code"] == "UNSAFE_AUDIENCE")
           )

    action =
      hd(s["actions"])
      |> Map.put("effects", [%{"op" => "set", "ref" => "world.noise", "value" => 1}])

    assert Enum.any?(
             Content.validate(Map.put(s, "actions", [action | tl(s["actions"])]))["errors"],
             &(&1["code"] == "TYPE_MISMATCH")
           )
  end

  test "the preset-only route matches the independent golden trace" do
    e =
      Enum.reduce(
        ~w(ask move:dining_hall unlock move:hall_kitchen switch_off),
        initial(),
        fn action, e -> step(e, %{"guest" => action}) end
      )

    assert e["ending"] == "safe"

    actual =
      Enum.map(e["settlements"], fn x ->
        %{
          "round" => x["round"],
          "step" => x["step"],
          "order" => x["order"],
          "result" => Enum.map(x["results"], &[&1["actor"], &1["status"]]),
          "world" => x["world"]
        }
      end)

    assert actual == fixture("golden_safe_trace")
    assert Engine.project(e, "guest", 4)["room"]["ending"]["summary"] =~ "电源"
  end

  test "the configured fourth round ends without an extra fifth round" do
    e = Enum.reduce(1..4, initial(), fn _, e -> step(e, %{}) end)
    assert e["ending"] == "evacuated"
    assert e["round"] == 4
    assert {:ok, ended} = Engine.tick(e, e["deadline"])
    assert ended["status"] == "finished"
  end

  test "queued intent reserves budget, replacement failure leaves previous intent intact" do
    e = initial()
    assert {:ok, queued, result} = submit(e, "guest", "ask")
    assert queued["actors"]["guest"]["ap_remaining"] == 3
    assert queued["actors"]["guest"]["ap_reserved"] == 1
    assert {:error, "CONDITION_CHANGED", ^queued} = submit(queued, "guest", "switch_off")

    assert {:ok, cancelled, _} =
             cmd(queued, "guest", "action.cancel", %{"intent_id" => result["intent_id"]})

    assert cancelled["actors"]["guest"]["ap_remaining"] == 3
    assert cancelled["actors"]["guest"]["ap_reserved"] == 0
  end

  test "same command is idempotent and same key with different body conflicts" do
    e = initial()
    id = Ruxi.Util.id()
    body = %{"action_id" => "ask", "step_id" => e["step_id"]}
    assert {:ok, queued, receipt} = Engine.command(e, "guest", "action.submit", body, id, 2)

    assert {:ok, ^queued, ^receipt} =
             Engine.command(queued, "guest", "action.submit", body, id, 3)

    assert {:error, "IDEMPOTENCY_CONFLICT", ^queued} =
             Engine.command(queued, "guest", "round.end", %{}, id, 3)
  end

  test "simultaneous unique item contention rotates independently of arrival order" do
    e =
      initial()
      |> step(%{
        "guest" => "move:dining_hall",
        "doctor" => "move:dining_hall",
        "reporter" => "move:dining_hall"
      })

    e = step(e, %{"reporter" => "take_tool", "guest" => "take_tool", "doctor" => "take_tool"})
    assert e["ownership"]["fire_extinguisher"]["owner"] == "doctor"
    assert e["actors"]["guest"]["ap_remaining"] == 2
    assert e["actors"]["reporter"]["ap_remaining"] == 2
    assert e["actors"]["doctor"]["ap_remaining"] == 1

    assert Enum.count(List.last(e["settlements"])["results"], &(&1["status"] == "invalidated")) ==
             2

    assert Enum.all?(e["actors"], fn {_, a} -> a["ap_reserved"] == 0 end)
  end

  test "private discoveries and unknown location metadata do not cross audience" do
    e = step(initial(), %{"guest" => "inspect"})
    guest = Jason.encode!(Engine.project(e, "guest", 4))
    doctor = Jason.encode!(Engine.project(e, "doctor", 4))
    assert guest =~ "stain"
    refute doctor =~ "stain"
    refute doctor =~ "random_key"

    s =
      update_in(
        story(),
        ["locations"],
        &Enum.map(&1, fn l ->
          if l["id"] == "kitchen",
            do: Map.merge(l, %{"discovered" => false, "label" => "SECRET_CANARY_LOCATION"}),
            else: l
        end)
      )

    e = initial(s)
    view = Jason.encode!(Engine.project(e, "guest", 4))
    refute view =~ "SECRET_CANARY_LOCATION"
    refute view =~ "hall_kitchen"
    e = step(e, %{"guest" => "move:dining_hall"})
    assert {:error, "CONDITION_CHANGED", ^e} = submit(e, "guest", "move:hall_kitchen")
  end

  test "a permitted free-action proposal costs nothing until explicit confirmation" do
    e =
      initial()
      |> step(%{"guest" => "move:dining_hall"})
      |> step(%{"guest" => "take_tool"})
      |> step(%{})

    assert {:ok, proposed, proposal} =
             Engine.proposal(
               e,
               "guest",
               %{"template_id" => "force_door", "target_id" => "door"},
               4
             )

    assert proposed["actors"]["guest"]["ap_remaining"] == 3
    assert proposal["cost"] == 2
    assert {:error, "FORBIDDEN", ^proposed} = submit(proposed, "guest", "force_door", 5)
    body = %{"proposal_id" => proposal["proposal_id"], "step_id" => proposed["step_id"]}

    paused = Engine.resume(Engine.suspend(proposed, 10), 20_000)

    assert {:error, "PROPOSAL_EXPIRED", ^paused} =
             cmd(paused, "guest", "action.submit", body, proposal["expires_at"])

    assert {:ok, queued, _} = cmd(proposed, "guest", "action.submit", body, 5)
    assert queued["actors"]["guest"]["ap_reserved"] == 2
    assert {:ok, resolved} = Engine.resolve(queued, 6)
    assert resolved["world"]["door_open"]
    assert resolved["world"]["noise"]
  end

  test "a stale quote or foreign proposal cannot execute" do
    e = initial()
    {:ok, e, p} = Engine.proposal(e, "guest", %{"mapped_action_id" => "ask"}, 2)
    body = %{"proposal_id" => p["proposal_id"], "step_id" => e["step_id"]}
    assert {:error, "PROPOSAL_EXPIRED", ^e} = cmd(e, "doctor", "action.submit", body)
    changed = put_in(e, ["world", "noise"], true)
    assert {:error, "PROPOSAL_STALE", ^changed} = cmd(changed, "guest", "action.submit", body)

    assert {:error, "PROPOSAL_EXPIRED", ^e} =
             cmd(e, "guest", "action.submit", Map.put(body, "proposal_id", "missing"))
  end

  test "probability is server-derived and retrying the committed command cannot reroll" do
    s =
      update_in(
        story(),
        ["actions"],
        &Enum.map(&1, fn a -> if a["id"] == "inspect", do: Map.put(a, "threshold", 1), else: a end)
      )

    e = initial(s)
    id = Ruxi.Util.id()
    b = %{"action_id" => "inspect", "step_id" => e["step_id"]}
    {:ok, e, receipt} = Engine.command(e, "guest", "action.submit", b, id, 2)
    {:ok, settled} = Engine.resolve(e, 3)
    result = Enum.find(List.last(settled["settlements"])["results"], &(&1["actor"] == "guest"))
    assert result["roll"] in 1..100
    assert settled["actors"]["guest"]["ap_remaining"] == 2
    assert {:ok, ^settled, ^receipt} = Engine.command(settled, "guest", "action.submit", b, id, 4)
  end

  test "event loops roll back the entire step before suspension" do
    e = initial()

    event = %{
      "id" => "loop",
      "trigger" => "action_end",
      "priority" => 1,
      "condition" => %{"op" => "all", "args" => []},
      "effects" => [%{"op" => "set", "ref" => "world.noise", "value" => true}],
      "once" => false
    }

    e = update_in(e, ["content", "events"], &[event | &1])
    {:ok, queued, _} = submit(e, "guest", "inspect")
    assert {:error, "RULE_LOOP", suspended} = Engine.resolve(queued, 3)
    assert suspended["status"] == "suspended"
    assert suspended["world"] == queued["world"]
    assert suspended["actors"] == queued["actors"]
    assert suspended["settlements"] == []
  end

  test "media summary confirms only authorized cue and waiting preserves acknowledgements" do
    e = Engine.initial(story(), 0)
    id = hd(e["cues"])["id"]
    {:ok, one, _} = cmd(e, "guest", "media.complete", %{"cue_id" => id, "mode" => "summary"})
    assert {:ok, suspended} = Engine.tick(one, 300_000)
    assert suspended["status"] == "suspended"
    resumed = Engine.resume(suspended, 300_100)
    assert id in resumed["cue_acks"]["guest"]

    assert {:error, "FORBIDDEN", ^resumed} =
             cmd(
               resumed,
               "guest",
               "media.complete",
               %{"cue_id" => "unknown", "mode" => "summary"},
               300_101
             )
  end

  test "media timeout recovery gives the barrier a new window and keeps acknowledgements" do
    e = Engine.initial(story(), 0)
    cue = hd(e["cues"])

    {:ok, e, _} =
      cmd(e, "guest", "media.complete", %{"cue_id" => cue["id"], "mode" => "summary"}, 1)

    {:ok, paused} = Engine.tick(e, 300_001)
    assert paused["status"] == "suspended"
    resumed = Engine.resume(paused, 600_000)
    {:ok, live} = Engine.tick(resumed, 600_001)
    assert live["status"] == "active"
    assert live["cue_acks"] == e["cue_acks"]
    assert live["barrier"]["deadline"] == 900_000
  end

  test "one player independently reaches either last-letter ending" do
    story = fixture("last_letter")
    assert Content.validate(story)["valid"]

    for {choice, ending} <- [{"deliver", "dawn"}, {"keep", "kept"}] do
      state = initial(story)

      state =
        Enum.reduce(
          ~w(read_letter inspect_photo move:office_archive read_ledger open_box move:archive_office),
          state,
          fn action, state ->
            state =
              if state["actors"]["keeper"]["ap_remaining"] == 0 do
                {:ok, next, _} = cmd(state, "keeper", "round.end", %{})
                next
              else
                state
              end

            next = step(state, [{"keeper", action}])

            Enum.reduce(next["cues"], next, fn cue, state ->
              {:ok, state, _} =
                cmd(state, "keeper", "media.complete", %{
                  "cue_id" => cue["id"],
                  "mode" => "summary"
                })

              state
            end)
          end
        )

      state = step(state, [{"keeper", choice}])
      assert state["ending"] == ending
      own = Engine.project(state, "keeper", 4)["own_results"]
      assert Enum.all?(own, &(&1["label"] != nil))
      refute Enum.any?(own, &(Map.has_key?(&1, "actor") or Map.has_key?(&1, "roll")))
    end
  end

  test "action feedback exposes only the viewing actor's settled facts" do
    state = step(initial(), [{"guest", "ask"}])
    own = Engine.project(state, "guest", 4)["own_results"]
    other = Engine.project(state, "doctor", 4)
    assert [%{"action_id" => "ask", "success" => true, "cost" => 1}] = own
    assert other["own_results"] == []
    assert other["knowledge"] == []
    refute Map.has_key?(hd(own), "roll")
    refute Map.has_key?(hd(own), "actor")
  end
end
