defmodule Ruxi.PreviewTest do
  use ExUnit.Case, async: true
  alias Ruxi.{Preview, Util}
  @now 1_800_000_000_000
  @roles ~w(investigator passenger conductor)

  def version do
    %{"id" => Util.id(), "revision" => 1, "content_hash" => "fixture-hash"}
  end

  def step(preview, owner, v, role, type, payload, extra \\ %{}) do
    Preview.step(
      preview["preview_token"],
      owner,
      v,
      Map.merge(
        %{"actor_role" => role, "type" => type, "payload" => payload, "command_id" => Util.id()},
        extra
      ),
      @now
    )
  end

  def explore(owner, v) do
    p = Preview.create(v, owner, @now)

    p =
      Enum.reduce(@roles, p, fn role, p ->
        step(p, owner, v, role, "media_complete", %{
          "media_id" => "opening",
          "media_epoch" => 1,
          "mode" => "summary"
        })
      end)

    Enum.reduce(@roles, p, fn role, p ->
      step(p, owner, v, role, "media_complete", %{
        "media_id" => "role_" <> role,
        "media_epoch" => 1,
        "mode" => "summary"
      })
    end)
  end

  test "preview uses real private projections, then reveals only explicit shared clues" do
    v = version()
    owner = Util.id()
    p = explore(owner, v)
    before = p["views"]["passenger"]
    p = step(p, owner, v, "investigator", "investigate", %{"action_id" => "inspect_monitor"})
    assert p["views"]["passenger"] == before
    assert p["views"]["investigator"]["own_clues"] |> Enum.any?(&(&1["clue_id"] == "C1"))
    assert List.last(p["history"])["changed_fields"]["passenger"] == []
    p = step(p, owner, v, "investigator", "share_clue", %{"clue_id" => "C1"})
    assert Jason.encode!(p["views"]["passenger"]["public_scene"]) =~ "C1"
  end

  test "tampered, foreign, expired and stale revision preview tokens are rejected" do
    v = version()
    owner = Util.id()
    p = Preview.create(v, owner, @now)

    assert catch_throw(step(p, Util.id(), v, "investigator", "advance_time", %{"delta_ms" => 1})) ==
             {:error, "NOT_ALLOWED"}

    assert catch_throw(
             step(p, owner, Map.put(v, "revision", 2), "investigator", "advance_time", %{
               "delta_ms" => 1
             })
           ) == {:error, "REVISION_CONFLICT"}

    assert catch_throw(Preview.version_id("forged")) == {:error, "INVALID_ARGUMENT"}

    params = %{
      "actor_role" => "investigator",
      "type" => "advance_time",
      "payload" => %{"delta_ms" => 1}
    }

    assert catch_throw(Preview.step(p["preview_token"], owner, v, params, @now + 1_800_000)) ==
             {:error, "PREVIEW_EXPIRED"}
  end

  test "sandbox time reaches the default ending without advancing a live room" do
    v = version()
    owner = Util.id()
    p = explore(owner, v)
    p = step(p, owner, v, "investigator", "advance_time", %{"delta_ms" => 180_000})

    p =
      Enum.reduce(@roles, p, fn role, p ->
        step(p, owner, v, role, "media_complete", %{
          "media_id" => "interlude",
          "media_epoch" => 1,
          "mode" => "summary"
        })
      end)

    p = step(p, owner, v, "investigator", "advance_time", %{"delta_ms" => 45_000})
    assert p["views"]["investigator"]["room"]["ending_code"] == "E3"
  end

  test "editor can play the actual three-role transfer and truth route" do
    v = version()
    owner = Util.id()
    p = explore(owner, v)
    p = step(p, owner, v, "investigator", "investigate", %{"action_id" => "inspect_monitor"})
    p = step(p, owner, v, "investigator", "share_clue", %{"clue_id" => "C1"})
    p = step(p, owner, v, "passenger", "investigate", %{"action_id" => "inspect_phone"})
    conductor = p["views"]["conductor"]["self"]["membership_id"]

    p =
      step(
        p,
        owner,
        v,
        "passenger",
        "offer_item",
        %{"item_id" => "C2", "to_member" => conductor},
        %{"target_version" => 1}
      )

    offer = p["result"]["offer_id"]
    p = step(p, owner, v, "conductor", "accept_offer", %{"offer_id" => offer})
    p = step(p, owner, v, "conductor", "investigate", %{"action_id" => "open_cabinet"})
    p = step(p, owner, v, "conductor", "share_clue", %{"clue_id" => "C3"})
    p = step(p, owner, v, "investigator", "advance_time", %{"delta_ms" => 180_000})

    p =
      Enum.reduce(@roles, p, fn role, p ->
        step(p, owner, v, role, "media_complete", %{
          "media_id" => "interlude",
          "media_epoch" => 1,
          "mode" => "summary"
        })
      end)

    round = p["views"]["investigator"]["vote_round"]["round_id"]

    p =
      Enum.reduce(~w(investigator passenger), p, fn role, p ->
        step(p, owner, v, role, "vote", %{"round_id" => round, "option_id" => "publish"})
      end)

    p = step(p, owner, v, "investigator", "advance_time", %{"delta_ms" => 45_000})
    assert p["views"]["conductor"]["room"]["ending_code"] == "E1"
  end
end
