defmodule Ruxi.RetentionTest do
  use ExUnit.Case
  alias Ruxi.{DB, Util, Rules, Content, Retention}
  @day 86_400_000
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()
    %{now: DB.time()}
  end

  def fixture(now, age, lifecycle) do
    room = Util.id()
    member = Util.id()
    user = Util.id()
    DB.query("INSERT INTO users(id,display_name) VALUES($1,'合成测试玩家')", [DB.uuid(user)])

    state =
      Rules.initial(room, Content.version_id(), member, now)
      |> Rules.add_member(member, user, now)
      |> Rules.update_member(
        member,
        &Map.merge(&1, %{
          "role" => "investigator",
          "hints" => [%{"hint_id" => Util.id(), "text" => "canary-hint", "source" => "template"}]
        })
      )
      |> Map.merge(%{
        "lifecycle" => lifecycle,
        "phase" => "ending",
        "ending" => "E3",
        "chat" => [%{"id" => Util.id(), "from" => member, "text" => "canary-chat", "at" => now}]
      })

    DB.query(
      "INSERT INTO rooms(id,content_version_id,state_json,lifecycle,updated_at,terminal_at) VALUES($1,$2,$3,$4,$5,$6)",
      [
        DB.uuid(room),
        DB.uuid(Content.version_id()),
        state,
        lifecycle,
        now - age,
        if(lifecycle in ~w(finished abandoned), do: now - age, else: nil)
      ]
    )

    DB.query(
      "INSERT INTO room_members(id,room_id,user_id,role_code,view_seq) VALUES($1,$2,$3,'investigator',1)",
      [DB.uuid(member), DB.uuid(room), DB.uuid(user)]
    )

    DB.query(
      "INSERT INTO member_view_events(room_id,member_id,seq,event_json) VALUES($1,$2,1,$3)",
      [DB.uuid(room), DB.uuid(member), %{"text" => "canary-history"}]
    )

    DB.query("INSERT INTO outbox(room_id,member_id,seq,delivered_at) VALUES($1,$2,1,$3)", [
      DB.uuid(room),
      DB.uuid(member),
      now - age
    ])

    DB.query(
      "INSERT INTO work_items(id,room_id,member_id,kind,input_json,basis,status,created_at,result_json) VALUES($1,$2,$3,'player_hint',$4,'{}','done',$5,$6)",
      [
        DB.uuid(Util.id()),
        DB.uuid(room),
        DB.uuid(member),
        %{"template" => "canary-input"},
        now - age,
        %{"narrative" => "canary-result"}
      ]
    )

    room
  end

  test "7-day purge scrubs all body copies and forces snapshot without removing recap", %{
    now: now
  } do
    room = fixture(now, 8 * @day, "finished")
    assert {:ok, %{"rooms_processed" => 1}} = Retention.run(now)
    row = DB.one("SELECT * FROM rooms WHERE id=$1", [DB.uuid(room)])
    refute Jason.encode!(row["state_json"]) =~ "canary"
    assert row["bodies_purged_at"] == now

    assert DB.one("SELECT count(*) AS n FROM member_view_events WHERE room_id=$1", [DB.uuid(room)])[
             "n"
           ] == 0

    assert DB.one("SELECT count(*) AS n FROM outbox WHERE room_id=$1", [DB.uuid(room)])["n"] == 0

    cursor =
      DB.one("SELECT view_seq,replay_floor_seq FROM room_members WHERE room_id=$1", [
        DB.uuid(room)
      ])

    assert cursor["view_seq"] > 1 and cursor["replay_floor_seq"] == cursor["view_seq"]

    job =
      DB.one("SELECT input_json,result_json FROM work_items WHERE room_id=$1", [DB.uuid(room)])

    assert job == %{"input_json" => %{}, "result_json" => nil}
    assert {:ok, %{"rooms_processed" => 0}} = Retention.run(now)
  end

  test "180-day purge removes dependencies but never age-cleans active recovery rooms", %{
    now: now
  } do
    old = fixture(now, 181 * @day, "abandoned")
    active = fixture(now, 200 * @day, "suspended")
    assert {:ok, %{"rooms_processed" => 1}} = Retention.run(now)
    assert DB.one("SELECT id FROM rooms WHERE id=$1", [DB.uuid(old)]) == nil

    assert DB.one("SELECT count(*) AS n FROM work_items WHERE room_id=$1", [DB.uuid(old)])["n"] ==
             0

    assert DB.one("SELECT lifecycle FROM rooms WHERE id=$1", [DB.uuid(active)])["lifecycle"] ==
             "suspended"

    assert DB.one("SELECT count(*) AS n FROM member_view_events WHERE room_id=$1", [
             DB.uuid(active)
           ])["n"] == 1
  end
end
