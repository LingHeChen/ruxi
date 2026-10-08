defmodule Ruxi.PublicRecapTest do
  use ExUnit.Case
  alias Ruxi.{Auth, Content, DB, PublicRecap, Rules, Store, Util}

  test "recap records only shared milestones and excludes private discoveries and chat" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()
    {:ok, guest} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    ctx = Auth.authenticate(guest["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    old = Store.load!(room["room_id"])["state_json"]
    member = hd(old["members"])["id"]

    private =
      Rules.update_member(
        old,
        member,
        &Map.merge(&1, %{"role" => "investigator", "known" => ["C1"]})
      )

    {:ok, private} =
      DB.transaction(fn -> Store.save(old, private, "clue_discovered", DB.time()) end)

    assert PublicRecap.restore(DB.uuid(room["room_id"])) == []
    assert Rules.project(private, member)["public_scene"]["timeline"] == []
    shared = Map.put(private, "shared", ["C1"])

    {:ok, shared} =
      DB.transaction(fn -> Store.save(private, shared, "clue_shared", DB.time()) end)

    [event] = PublicRecap.restore(DB.uuid(room["room_id"]))
    assert event["kind"] == "shared_clue"
    refute Map.has_key?(event, "user_id")
    refute Map.has_key?(event, "text")
    assert Rules.project(shared, member)["public_scene"]["timeline"] == [event]

    chat =
      Map.put(shared, "chat", [
        %{
          "message_id" => Util.id(),
          "sender_member" => member,
          "text" => "private diagnostic canary",
          "sent_at" => Util.iso(DB.time())
        }
      ])

    {:ok, _} = DB.transaction(fn -> Store.save(shared, chat, "chat_added", DB.time()) end)
    assert PublicRecap.restore(DB.uuid(room["room_id"])) == [event]
    refute Jason.encode!(event) =~ "private diagnostic canary"
  end
end
