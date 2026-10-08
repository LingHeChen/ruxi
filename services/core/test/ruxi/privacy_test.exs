defmodule Ruxi.PrivacyTest do
  use ExUnit.Case
  alias Ruxi.{Auth, DB, Util, Content, Privacy, Rules, Store}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()
    old = System.get_env("ERASURE_LEDGER_PATH")
    path = Path.join(System.tmp_dir!(), "ruxi-erasure-#{Util.id()}.jsonl")
    System.put_env("ERASURE_LEDGER_PATH", path)

    on_exit(fn ->
      File.rm(path)

      if old,
        do: System.put_env("ERASURE_LEDGER_PATH", old),
        else: System.delete_env("ERASURE_LEDGER_PATH")
    end)

    device = Util.id()
    {:ok, auth} = Auth.guest(%{"device_id" => device, "command_id" => Util.id()})
    ctx = Auth.authenticate(auth["access_token"])
    %{ctx: ctx, auth: auth, path: path}
  end

  def fixture(ctx, lifecycle) do
    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    rid = room["room_id"]
    old = Store.load!(rid)["state_json"]
    now = DB.time()
    peer = Util.id()
    peer_user = Util.id()
    DB.query("INSERT INTO users(id,display_name) VALUES($1,'队友')", [DB.uuid(peer_user)])

    DB.query("INSERT INTO room_members(id,room_id,user_id) VALUES($1,$2,$3)", [
      DB.uuid(peer),
      DB.uuid(rid),
      DB.uuid(peer_user)
    ])

    new =
      old
      |> Rules.add_member(peer, peer_user, now)
      |> Map.merge(%{
        "lifecycle" => lifecycle,
        "phase" => if(lifecycle == "finished", do: "ending", else: "exploration"),
        "phase_id" => Util.id(),
        "ending" => if(lifecycle == "finished", do: "E1", else: nil),
        "chat" => [
          %{
            "id" => Util.id(),
            "from" => old["members"] |> hd() |> Map.fetch!("id"),
            "text" => "private-canary",
            "at" => now
          }
        ]
      })

    DB.transaction(fn -> Store.save(old, new, "lifecycle_changed", now) end)
    {rid, new, peer}
  end

  test "erasure scrubs shared copies, preserves joint result and revokes all recovery", %{
    ctx: ctx,
    auth: auth,
    path: path
  } do
    {rid, _, peer} = fixture(ctx, "finished")

    sender =
      DB.one("SELECT id FROM room_members WHERE room_id=$1 AND user_id=$2", [
        DB.uuid(rid),
        DB.uuid(ctx.user)
      ])["id"]

    report = DB.uuid(Util.id())

    DB.query(
      "INSERT INTO chat_reports(id,room_id,reporter_user_id,sender_member_id,message_id,message_text,reason) VALUES($1,$2,$3,$4,$5,'private-canary','privacy')",
      [report, DB.uuid(rid), DB.uuid(ctx.user), sender, DB.uuid(Util.id())]
    )

    DB.query(
      "INSERT INTO telemetry_events(event_id,user_id,session_id,event_name,schema_version,app_version,occurred_at,properties) VALUES($1,$2,$3,'screen_view',1,'0.1.0',clock_timestamp(),'{\"screen\":\"entry\"}')",
      [DB.uuid(Util.id()), DB.uuid(ctx.user), DB.uuid(Util.id())]
    )

    assert {:ok, %{"erased" => true}} =
             Privacy.erase(ctx, %{"command_id" => Util.id(), "confirmation" => "ERASE_ACCOUNT"})

    row = Store.load!(rid)
    assert row["state_json"]["ending"] == "E1"

    assert DB.one(
             "SELECT message_text,reporter_user_id,sender_member_id FROM chat_reports WHERE id=$1",
             [report]
           ) == %{"message_text" => nil, "reporter_user_id" => nil, "sender_member_id" => nil}

    assert DB.one("SELECT count(*) AS n FROM telemetry_events WHERE user_id=$1", [
             DB.uuid(ctx.user)
           ])["n"] == 0

    assert length(row["state_json"]["members"]) == 2
    assert Rules.member(row["state_json"], peer)["name"] == "玩家 2"
    refute Jason.encode!(row["state_json"]) =~ "private-canary"

    assert Enum.find(row["state_json"]["members"], &(&1["user_id"] == ctx.user))["name"] ==
             "已注销玩家"

    assert catch_throw(Auth.authenticate(auth["access_token"])) == {:error, "UNAUTHORIZED"}

    assert {:error, "UNAUTHORIZED"} =
             Auth.recover(%{
               "recovery_code" => auth["recovery_code"],
               "device_id" => Util.id(),
               "recovery_request_id" => Util.id()
             })

    assert DB.one("SELECT count(*) AS n FROM member_view_events WHERE room_id=$1", [DB.uuid(rid)])[
             "n"
           ] == 0

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert Privacy.replay() == %{"replayed" => 1}
  end

  test "active erasure terminates original seats; independently replayed intent scrubs restored backup",
       %{ctx: ctx} do
    {rid, before, _} = fixture(ctx, "running")

    assert {:ok, _} =
             Privacy.erase(ctx, %{"command_id" => Util.id(), "confirmation" => "ERASE_ACCOUNT"})

    assert Store.load!(rid)["lifecycle"] == "abandoned"
    DB.query("UPDATE users SET status='active' WHERE id=$1", [DB.uuid(ctx.user)])

    DB.query("UPDATE rooms SET state_json=$2,lifecycle='running',terminal_at=NULL WHERE id=$1", [
      DB.uuid(rid),
      before
    ])

    assert Privacy.replay() == %{"replayed" => 1}
    after_restore = Store.load!(rid)["state_json"]
    refute Jason.encode!(after_restore) =~ "private-canary"
    assert after_restore["lifecycle"] == "abandoned"
    assert length(after_restore["members"]) == 2
    generation = Enum.find(after_restore["members"], &(&1["user_id"] == ctx.user))["generation"]
    Privacy.replay()

    assert Enum.find(Store.load!(rid)["state_json"]["members"], &(&1["user_id"] == ctx.user))[
             "generation"
           ] == generation
  end

  test "invalid confirmation cannot write a durable erasure intent", %{ctx: ctx, path: path} do
    assert catch_throw(Privacy.erase(ctx, %{"command_id" => Util.id(), "confirmation" => "no"})) ==
             {:error, "INVALID_ARGUMENT"}

    refute File.exists?(path)
    Auth.valid!(ctx)
  end
end
