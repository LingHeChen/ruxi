defmodule Ruxi.ContentASTTest do
  use ExUnit.Case, async: true
  alias Ruxi.{Content, ContentAST, Rules, Util}

  test "all three endings are independently reachable within the finite state budget" do
    report = ContentAST.compile(Content.demo_graph())
    assert report["valid"] and report["complete"]
    assert report["reachable_endings"] == ~w(E1 E2 E3)
    assert report["states_checked"] == 37
    assert ContentAST.compile(Content.demo_graph(), 5)["complete"] == false
    assert ContentAST.compile(Content.demo_graph(), 5)["valid"] == false
  end

  test "unknown scripts, private decision conditions, variables and visibility fail closed" do
    g = Content.demo_graph()
    bad = put_in(g, ["actions", Access.at(0), "requires"], %{"eval" => "system('anything')"})
    refute ContentAST.compile(bad)["valid"]
    bad = put_in(g, ["decision", "eligibility", "publish"], %{"knows_clue" => "C3"})
    refute ContentAST.compile(bad)["valid"]

    bad =
      put_in(g, ["actions", Access.at(0), "effects"], [
        %{"set_variable" => "missing", "value" => true}
      ])

    refute ContentAST.compile(bad)["valid"]

    bad =
      put_in(
        g,
        ["actions", Access.at(0), "effects", Access.at(0), "visibility"],
        "everyone_except_actor"
      )

    refute ContentAST.compile(bad)["valid"]
    refute ContentAST.compile(Map.put(g, "server_script", "anything"))["valid"]
  end

  test "unreachable final evidence and conditional defaults block publication" do
    g = Content.demo_graph()
    bad = put_in(g, ["actions", Access.at(2), "requires"], %{"public_clue" => "C3"})
    report = ContentAST.compile(bad)
    refute report["valid"]
    assert "unreachable ending: E1" in report["errors"]
    bad = put_in(g, ["decision", "eligibility", "leave"], %{"not" => %{"public_clue" => "C3"}})
    refute ContentAST.compile(bad)["valid"]
  end

  test "two and four seat formats validate their role and media bindings" do
    g = Content.demo_graph()

    g = %{
      g
      | "seat_count" => 2,
        "roles" => ~w(investigator passenger),
        "actions" => Enum.take(g["actions"], 2)
    }

    g = put_in(g, ["decision", "options"], ~w(leave wait))
    g = put_in(g, ["decision", "tie_priority"], ~w(leave wait))
    g = put_in(g, ["decision", "eligibility"], %{})
    g = put_in(g, ["decision", "endings"], %{"leave" => "E3", "wait" => "E2"})

    g = %{
      g
      | "media" => Enum.reject(g["media"], &(&1 in ~w(role_conductor ending_E1))),
        "assets" => Enum.reject(g["assets"], &(&1["media_id"] in ~w(role_conductor ending_E1)))
    }

    assert ContentAST.compile(g)["valid"]
    base = Content.demo_graph()

    fourth =
      base["assets"]
      |> Enum.at(3)
      |> Map.merge(%{"media_id" => "role_observer", "asset_id" => Util.id()})

    g = %{
      base
      | "seat_count" => 4,
        "roles" => base["roles"] ++ ["observer"],
        "media" => base["media"] ++ ["role_observer"],
        "assets" => base["assets"] ++ [fourth]
    }

    assert ContentAST.compile(g)["valid"]
    refute ContentAST.compile(Map.put(g, "seat_count", 3))["valid"]
  end

  test "runtime uses the frozen graph rather than hardcoded actions and timing" do
    g = Content.demo_graph() |> put_in(["timing", "exploration_ms"], 60_000)
    g = put_in(g, ["actions", Access.at(0), "id"], "inspect_records")
    s = Rules.initial(Util.id(), Util.id(), "A", 0, g)

    s =
      Enum.reduce(Enum.with_index(g["roles"]), s, fn {role, i}, s ->
        id = Enum.at(~w(A B C), i)
        s = Rules.add_member(s, id, Util.id(), 0) |> Rules.presence(id, true, 0)
        {s, _, _} = Rules.apply(s, id, "select_role", %{"role_code" => role}, 0)
        {s, _, _} = Rules.apply(s, id, "ready", %{"ready" => true}, 0)
        s
      end)

    {s, _, _} = Rules.apply(s, "A", "start", %{}, 0)

    s =
      Enum.reduce(~w(A B C), s, fn id, s ->
        elem(
          Rules.apply(
            s,
            id,
            "media_complete",
            %{"media_id" => "opening", "media_epoch" => 1, "mode" => "summary"},
            0
          ),
          0
        )
      end)

    s =
      Enum.reduce(Enum.zip(~w(A B C), g["roles"]), s, fn {id, role}, s ->
        elem(
          Rules.apply(
            s,
            id,
            "media_complete",
            %{"media_id" => "role_" <> role, "media_epoch" => 1, "mode" => "summary"},
            0
          ),
          0
        )
      end)

    assert s["deadline"] == 60_000

    assert catch_throw(Rules.apply(s, "A", "investigate", %{"action_id" => "inspect_monitor"}, 0)) ==
             {:error, "NOT_ALLOWED"}

    {s, _, _} = Rules.apply(s, "A", "investigate", %{"action_id" => "inspect_records"}, 0)
    assert Rules.member(s, "A")["known"] == ["C1"]

    assert catch_throw(Rules.apply(s, "A", "investigate", %{"action_id" => "inspect_records"}, 0)) ==
             {:error, "NOT_ALLOWED"}
  end
end
