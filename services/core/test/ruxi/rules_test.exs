defmodule Ruxi.RulesTest do
  use ExUnit.Case, async: true
  alias Ruxi.{Rules, Util}

  def fixture do
    ids = Enum.map(1..3, fn _ -> Util.id() end)
    s = Rules.initial(Util.id(), Ruxi.Content.version_id(), hd(ids), 1000)

    s =
      Enum.reduce(ids, s, fn id, s ->
        Rules.add_member(s, id, Util.id(), 1000)
        |> Rules.update_member(id, &Map.put(&1, "online", true))
      end)

    {s, ids}
  end

  def cmd(s, id, t, p \\ %{}, now \\ 1000), do: elem(Rules.apply(s, id, t, p, now), 0)

  def exploration do
    {s, [a, b, c] = ids} = fixture()

    s =
      Enum.zip(ids, ~w(investigator passenger conductor))
      |> Enum.reduce(s, fn {id, role}, s ->
        s
        |> cmd(id, "select_role", %{"role_code" => role})
        |> cmd(id, "ready", %{"ready" => true})
      end)

    s = cmd(s, a, "start")

    s =
      Enum.reduce(ids, s, fn id, s ->
        cmd(s, id, "media_complete", %{
          "media_id" => "opening",
          "media_epoch" => 1,
          "mode" => "summary"
        })
      end)

    s =
      Enum.zip([a, b, c], ~w(investigator passenger conductor))
      |> Enum.reduce(s, fn {id, r}, s ->
        cmd(s, id, "media_complete", %{
          "media_id" => "role_" <> r,
          "media_epoch" => 1,
          "mode" => "summary"
        })
      end)

    {s, ids}
  end

  def decision(s, ids) do
    s = Enum.reduce(ids, s, &cmd(&2, &1, "confirm_exploration_end"))
    assert s["step"] == "interlude"

    assert catch_throw(cmd(s, hd(ids), "request_hint", %{"hint_level" => 1})) ==
             {:error, "NOT_ALLOWED"}

    Enum.reduce(ids, s, fn id, s ->
      cmd(s, id, "media_complete", %{
        "media_id" => "interlude",
        "media_epoch" => 1,
        "mode" => "summary"
      })
    end)
  end

  test "golden truth chain, private clues and unique transfer" do
    {s, [a, b, c] = ids} = exploration()
    s = cmd(s, a, "investigate", %{"action_id" => "inspect_monitor"})
    assert Rules.project(s, b)["own_clues"] == []
    refute Jason.encode!(Rules.project(s, b)) =~ "第七处被擦去"
    s = cmd(s, a, "share_clue", %{"clue_id" => "C1"})
    s = cmd(s, b, "investigate", %{"action_id" => "inspect_phone"})
    refute Jason.encode!(Rules.project(s, a)) =~ "23:17，与旧车票一致"

    {s, r, _} =
      Rules.apply(
        s,
        b,
        "offer_item",
        %{"item_id" => "C2", "to_member" => c, "target_version" => 1},
        1000
      )

    assert s["items"]["C2"]["owner"] == b
    s = cmd(s, c, "accept_offer", %{"offer_id" => r["offer_id"]})
    assert s["items"]["C2"] == %{"owner" => c, "version" => 2}

    assert catch_throw(cmd(s, c, "accept_offer", %{"offer_id" => r["offer_id"]})) ==
             {:error, "TARGET_CHANGED"}

    s =
      s
      |> cmd(c, "investigate", %{"action_id" => "open_cabinet"})
      |> cmd(c, "share_clue", %{"clue_id" => "C3"})
      |> decision(ids)

    s =
      s
      |> cmd(a, "vote", %{"round_id" => s["round"]["round_id"], "option_id" => "publish"})
      |> cmd(b, "vote", %{"round_id" => s["round"]["round_id"], "option_id" => "publish"})

    assert Rules.project(s, c)["own_vote"] == nil
    s = Rules.tick(s, s["deadline"])
    assert s["ending"] == "E1"
    assert Rules.tick(s, s["deadline"])["lifecycle"] == "finished"
  end

  test "unavailable evidence has safe display; wait and all abstain endings" do
    {s, ids} = exploration()
    s = decision(s, ids)
    assert Enum.map(s["round"]["options"], & &1["option_id"]) == ~w(leave wait)
    assert List.last(s["round"]["display_options"])["reason_text"] == "需公开关键证据"
    refute Jason.encode!(Rules.project(s, hd(ids))) =~ "C3"
    assert Rules.tick(s, s["deadline"])["ending"] == "E3"

    s =
      Enum.take(ids, 2)
      |> Enum.reduce(s, fn id, s ->
        cmd(s, id, "vote", %{"round_id" => s["round"]["round_id"], "option_id" => "wait"})
      end)

    assert Rules.tick(s, s["deadline"])["ending"] == "E2"
  end

  test "pause consensus cancels pending offer without consuming owner" do
    {s, [a, b, c]} = exploration()
    s = cmd(s, b, "investigate", %{"action_id" => "inspect_phone"})
    s = cmd(s, b, "offer_item", %{"item_id" => "C2", "to_member" => c, "target_version" => 1})
    s = cmd(s, a, "request_pause")
    req = s["pause_request"]["id"]

    s =
      s
      |> cmd(b, "confirm_pause", %{"pause_request_id" => req})
      |> cmd(c, "confirm_pause", %{"pause_request_id" => req})

    assert s["lifecycle"] == "paused"
    assert s["manual_pause_used"]
    assert hd(s["offers"])["status"] == "cancelled"
    assert s["items"]["C2"]["owner"] == b
    generation = s["timer_generation"]

    s =
      Enum.reduce([a, b, c], s, fn id, s ->
        cmd(s, id, "resume", %{"timer_generation" => generation}, 20_000)
      end)

    assert s["lifecycle"] == "running"
    assert s["deadline"] == 200_000
  end

  test "role exchange is atomic, clears readiness, ends on expiry" do
    {s, [a, b, _]} = fixture()

    s =
      s
      |> cmd(a, "select_role", %{"role_code" => "investigator"})
      |> cmd(b, "select_role", %{"role_code" => "passenger"})
      |> cmd(a, "ready", %{"ready" => true})

    s = cmd(s, a, "request_role_swap", %{"to_member" => b})
    rid = s["role_swap"]["id"]
    assert catch_throw(cmd(s, b, "ready", %{"ready" => true})) == {:error, "NOT_ALLOWED"}
    n = cmd(s, b, "accept_role_swap", %{"role_swap_id" => rid})
    assert Rules.member(n, a)["role"] == "passenger"
    refute Rules.member(n, a)["ready"]
    assert Rules.member(n, b)["role"] == "investigator"
    assert Rules.tick(s, 31_000)["role_swap"]["status"] == "expired"
  end

  test "interlude timeout resumes with new window; settled ending never suspends" do
    {s, _ids} = exploration()
    s = Rules.tick(s, s["deadline"])
    assert s["step"] == "interlude"
    s = Rules.tick(s, s["deadline"])
    assert s["lifecycle"] == "suspended"
    assert s["remaining"] == 300_000
    {s, ids} = exploration()
    s = decision(s, ids)
    s = Rules.tick(s, s["deadline"])
    n = Enum.reduce(ids, s, fn id, s -> Rules.presence(s, id, false, 46_001) end)
    assert n["lifecycle"] == "running"
    assert n["ending"] == "E3"
  end

  test "same intent digest excludes device generation, includes recovery epoch" do
    c = %{
      "control_generation" => 1,
      "recovery_epoch" => "A",
      "type" => "ready",
      "payload" => %{"ready" => true}
    }

    assert Ruxi.Contract.digest(c) == Ruxi.Contract.digest(Map.put(c, "control_generation", 2))
    refute Ruxi.Contract.digest(c) == Ruxi.Contract.digest(Map.put(c, "recovery_epoch", "B"))
  end
end
