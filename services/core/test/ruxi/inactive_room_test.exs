defmodule Ruxi.InactiveRoomTest do
  use ExUnit.Case
  alias Ruxi.{Auth, Content, DB, Maintenance, RoomServer, Store, Util}

  test "offline suspended room releases its process and expires through bounded maintenance" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Ruxi.Repo, {:shared, self()})
    Content.seed()
    {:ok, guest} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    ctx = Auth.authenticate(guest["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    old = Store.load!(room["room_id"])["state_json"]

    suspended =
      Map.merge(old, %{"lifecycle" => "suspended", "deadline" => nil, "suspended_at" => DB.time()})

    {:ok, _} =
      DB.transaction(fn -> Store.save(old, suspended, "lifecycle_changed", DB.time()) end)

    refute room["room_id"] in Ruxi.Dispatcher.recoverable_rooms()

    {:ok, pid} = RoomServer.ensure(room["room_id"])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2500
    refute Process.alive?(pid)
    wait_for_registry(room["room_id"], 50)
    assert Store.load!(room["room_id"])["owner_instance"] == nil
    expired = Map.put(suspended, "suspended_at", DB.time() - 86_400_001)

    {:ok, _} =
      DB.transaction(fn -> Store.save(suspended, expired, "lifecycle_changed", DB.time()) end)

    {:ok, _} = Maintenance.run()
    assert Store.load!(room["room_id"])["lifecycle"] == "abandoned"

    assert DB.one("SELECT count(*) AS n FROM room_summaries WHERE room_id=$1", [
             DB.uuid(room["room_id"])
           ])["n"] == 1
  end

  defp wait_for_registry(rid, remaining) do
    case Registry.lookup(Ruxi.RoomRegistry, rid) do
      [] ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(5)
        wait_for_registry(rid, remaining - 1)

      other ->
        flunk("inactive registry entry remained: #{inspect(other)}")
    end
  end
end
