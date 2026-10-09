defmodule Ruxi.C3EngineTest do
  use ExUnit.Case, async: true
  alias Ruxi.C2.{Engine, Content}
  alias Ruxi.C3.{Interactions, World}
  alias Ruxi.Util

  def story,
    do:
      File.read!(Path.expand("../../../content/c3/rain_archive.json", __DIR__)) |> Jason.decode!()

  def initial do
    s = Engine.initial(story(), 0)

    Enum.reduce(~w(investigator technician custodian), s, fn r, acc ->
      Enum.reduce(acc["cues"], acc, fn c, next ->
        {:ok, next, _} =
          Engine.command(
            next,
            r,
            "media.complete",
            %{"cue_id" => c["id"], "mode" => "summary"},
            Util.id(),
            1
          )

        next
      end)
    end)
  end

  def positioned(s, r, loc), do: s |> put_in(["actors", r, "location"], loc) |> World.observe(2)

  def quoted(s, r, id) do
    {:ok, s, q} = Interactions.quote(s, r, id, 2)
    {s, q}
  end

  def submit(s, r, q, answer \\ nil, id \\ Util.id()) do
    b = %{
      "quote_id" => q["quote_id"],
      "kind" => q["kind"],
      "input" => if(answer, do: %{"answer" => answer}, else: %{})
    }

    Engine.command(s, r, "interaction.submit", b, id, 3)
  end

  test "C3 validates and secrets never enter a role projection or quote" do
    assert Content.validate(story())["valid"]
    s = initial() |> positioned("investigator", "archive")
    {s, q} = quoted(s, "investigator", "safe_password")
    refute Jason.encode!(q) =~ "0427"
    view = Engine.project(s, "investigator", 2)
    refute Jason.encode!(view) =~ "safe_code"
    refute Jason.encode!(view) =~ "维修间"
    assert s["engine_version"] == 3
    assert s["protocol_version"] == 3
  end

  test "format failure is free; wrong answer consumes AP and counts; leading-zero answer solves" do
    s = initial() |> positioned("investigator", "archive")
    {s, q} = quoted(s, "investigator", "safe_password")
    assert {:error, "INPUT_INVALID", unchanged} = submit(s, "investigator", q, "427")
    assert unchanged == s
    {:ok, s, _} = submit(s, "investigator", q, "1111")
    assert s["actors"]["investigator"]["ap_reserved"] == 1
    assert s["world"]["safe_open"] == false
    assert Jason.encode!(s["intents"]) =~ "answer_cipher"
    refute Jason.encode!(s["intents"]) =~ "1111"
    {:ok, s} = Engine.resolve(s, 4)
    assert s["actors"]["investigator"]["ap_remaining"] == 2
    assert s["attempts"]["safe_password:room"]["used"] == 1
    refute Jason.encode!(s["settlements"]) =~ "answer_cipher"
    {s, q} = quoted(s, "investigator", "safe_password")
    {:ok, s, _} = submit(s, "investigator", q, "0427")
    {:ok, s} = Engine.resolve(s, 4)
    assert s["world"]["safe_open"]

    assert {:error, "TARGET_UNAVAILABLE", _} =
             Interactions.quote(s, "investigator", "safe_password", 5)
  end

  test "last room attempt serializes competing guesses and refunds later intent" do
    s = initial() |> positioned("investigator", "archive") |> positioned("custodian", "archive")
    s = put_in(s, ["attempts", "safe_password:room"], %{"used" => 2, "blocked_until_round" => 0})
    {s, q1} = quoted(s, "investigator", "safe_password")
    {s, q2} = quoted(s, "custodian", "safe_password")
    {:ok, s, _} = submit(s, "investigator", q1, "1111")
    {:ok, s, _} = submit(s, "custodian", q2, "0427")
    {:ok, s} = Engine.resolve(s, 4)
    assert s["attempts"]["safe_password:room"]["used"] == 3
    refute s["world"]["safe_open"]
    results = List.last(s["settlements"])["results"]
    assert Enum.find(results, &(&1["actor"] == "custodian"))["status"] == "invalidated"
    assert s["actors"]["custodian"]["ap_remaining"] == 3
    assert s["actors"]["custodian"]["ap_reserved"] == 0
  end

  test "check target clamps, quoted modifiers stale without any charge or draw" do
    s = initial() |> positioned("technician", "maintenance")
    i = Enum.find(Interactions.definitions(story()), &(&1["kind"] == "check"))

    for target <- [0, 1, 60, 100] do
      assert Enum.count(1..100, &(&1 <= target)) == target
    end

    assert {60, _} = Interactions.target(s, i, "technician", 2)
    {s, q} = quoted(s, "technician", "repair_power")
    {:ok, s, _} = submit(s, "technician", q)
    {:ok, s} = Engine.resolve(s, 4)
    result = hd(s["interaction_results"])
    assert result["roll"] in 1..100
    assert result["target"] == 60
    assert result["success"] == result["roll"] <= 60
    assert Interactions.normalize("  Ａß  ", "nfkc_trim_casefold") == "ass"
  end

  test "arrival seals return while remote observations stay unchanged and escape remains" do
    s =
      initial()
      |> put_in(["actors", "investigator", "known_locations"], ["duty", "archive", "exit"])

    {:ok, s, _} =
      Engine.command(
        s,
        "investigator",
        "action.submit",
        %{"step_id" => s["step_id"], "action_id" => "move:duty_archive_ab"},
        Util.id(),
        2
      )

    {:ok, s} = Engine.resolve(s, 3)
    assert s["barriers"]["return_gate"] == "blocked"
    own = Engine.project(s, "investigator", 3)["map"]["links"]
    assert Enum.find(own, &(&1["id"] == "duty_archive_ba"))["observed_state"] == "blocked"
    assert Enum.find(own, &(&1["id"] == "archive_exit_ab"))["allowed_now"]
    assert s["actors"]["custodian"]["map_observations"]["duty_archive_ab"]["allowed"]
  end

  test "faction goals stay private and copied knowledge survives destroyed evidence" do
    s = initial() |> positioned("investigator", "exit") |> positioned("custodian", "archive")

    s =
      s
      |> put_in(["world", "submitted"], true)
      |> put_in(["world", "destroyed"], true)
      |> put_in(["status"], "ending")

    inv = Engine.project(s, "investigator", 4)
    custodian = Engine.project(s, "custodian", 4)
    assert Enum.find(inv["self"]["objectives"], &(&1["id"] == "submit"))["result"] == "achieved"

    assert Enum.find(custodian["self"]["objectives"], &(&1["id"] == "cover"))["result"] ==
             "failed"

    refute Enum.any?(inv["self"]["objectives"], &(&1["id"] == "cover"))
    refute Jason.encode!(inv) =~ "隐秘目标"
  end

  test "NPC cannot traverse blocked gate and viewing does not tick the world" do
    story =
      story()
      |> put_in(["c3_settings", "npcs"], [
        %{
          "id" => "clerk",
          "label" => "值夜人",
          "location" => "archive",
          "schedule" => [%{"round" => 1, "link_id" => "duty_archive_ba"}]
        }
      ])

    assert Content.validate(story)["valid"]
    s = Engine.initial(story, 0) |> put_in(["barriers", "return_gate"], "blocked")
    same = Engine.project(s, "investigator", 1)
    assert same["room"]["round"] == 1
    s = Ruxi.C3.Domain.tick(s, 2)
    assert s["npc_states"]["clerk"]["location"] == "archive"
    assert Ruxi.C3.Domain.tick(s, 3) == s
  end

  test "compiler rejects unknown passage endpoints and concealed check modifiers" do
    s = story() |> put_in(["c3", "passages", Access.at(0), "a"], "missing")
    refute Content.validate(s)["valid"]

    s =
      story()
      |> put_in(["c3", "interactions", Access.at(1), "modifiers", Access.at(0), "when"], %{
        "op" => "eq",
        "ref" => "return_gate",
        "value" => "open"
      })

    refute Content.validate(s)["valid"]
  end

  test "modifier dependency changing after queue invalidates without a roll or charge" do
    story =
      story()
      |> update_in(
        ["c3", "interactions", Access.at(1), "modifiers"],
        &(&1 ++
            [
              %{
                "label" => "收据准备",
                "when" => %{"op" => "known", "ref" => "code"},
                "delta" => 10,
                "visibility" => "actor"
              }
            ])
      )

    s = Engine.initial(story, 0)

    s =
      Enum.reduce(s["cues"], s, fn c, acc ->
        Enum.reduce(Map.keys(acc["actors"]), acc, fn r, next ->
          {:ok, next, _} =
            Engine.command(
              next,
              r,
              "media.complete",
              %{"cue_id" => c["id"], "mode" => "summary"},
              Util.id(),
              1
            )

          next
        end)
      end)

    s = positioned(s, "technician", "maintenance")
    {s, q} = quoted(s, "technician", "repair_power")
    {:ok, s, _} = submit(s, "technician", q)
    s = update_in(s, ["actors", "technician", "knowledge"], &["code" | &1])
    {:ok, s} = Engine.resolve(s, 4)
    assert s["interaction_results"] == []
    assert s["actors"]["technician"]["ap_remaining"] == 3

    assert Enum.find(List.last(s["settlements"])["results"], &(&1["actor"] == "technician"))[
             "status"
           ] == "invalidated"
  end
end
