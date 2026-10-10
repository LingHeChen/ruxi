defmodule Ruxi.ElectorateTest do
  use ExUnit.Case
  alias Ruxi.{DB, Util, Auth, Content, Store, Rules}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()
    {:ok, guest} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    ctx = Auth.authenticate(guest["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    %{ctx: ctx, room: room}
  end

  test "voters are frozen before voting and deleted only with the round", %{room: room} do
    old = Store.load!(room["room_id"])["state_json"]
    member = hd(old["members"])["id"]

    interlude =
      old
      |> Rules.update_member(
        member,
        &Map.merge(&1, %{"role" => "investigator", "online" => true})
      )
      |> Map.merge(%{
        "lifecycle" => "running",
        "phase" => "exploration",
        "phase_id" => Util.id(),
        "step" => "interlude",
        "shared" => ["C3"],
        "media_epochs" => %{"interlude" => 1}
      })

    {new, _, _} =
      Rules.apply(
        interlude,
        member,
        "media_complete",
        %{"media_id" => "interlude", "media_epoch" => 1, "mode" => "summary"},
        DB.time()
      )

    {:ok, _} = DB.transaction(fn -> Store.save(old, new, "phase_changed", DB.time()) end)
    round = DB.uuid(new["round"]["round_id"])
    rid = DB.uuid(room["room_id"])

    assert DB.one("SELECT count(*) AS n FROM vote_electorate WHERE room_id=$1 AND round_id=$2", [
             rid,
             round
           ])["n"] == 1

    assert DB.one("SELECT electorate_frozen FROM vote_rounds WHERE room_id=$1 AND id=$2", [
             rid,
             round
           ])["electorate_frozen"]

    {:ok, _} =
      DB.transaction(fn ->
        DB.query(
          "INSERT INTO votes(room_id,round_id,member_id,option_id) VALUES($1,$2,$3,'leave')",
          [rid, round, DB.uuid(member)]
        )
      end)

    # Verify the actual trigger inside a savepoint so the outer test transaction survives.

    assert_raise Postgrex.Error, fn ->
      Ecto.Adapters.SQL.query!(
        Ruxi.Repo,
        "DELETE FROM vote_electorate WHERE room_id=$1 AND round_id=$2",
        [Ecto.UUID.dump!(DB.str(rid)), Ecto.UUID.dump!(DB.str(round))],
        mode: :savepoint
      )
    end

    DB.query("DELETE FROM votes WHERE room_id=$1", [rid])
    DB.query("DELETE FROM vote_rounds WHERE room_id=$1", [rid])
    assert DB.one("SELECT count(*) AS n FROM vote_electorate WHERE room_id=$1", [rid])["n"] == 0
  end
end
