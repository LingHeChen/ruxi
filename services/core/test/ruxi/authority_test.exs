defmodule Ruxi.AuthorityTest do
  use ExUnit.Case
  alias Ruxi.{Auth, Authority, Content, DB, Store, Util}

  test "ownership recovery replaces corrupt structural cache with committed SQL facts" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()
    {:ok, guest} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    ctx = Auth.authenticate(guest["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    row = Store.load!(room["room_id"])
    original = row["state_json"]

    corrupted =
      original
      |> Map.put("content", %{"title" => "uncommitted"})
      |> Map.put("items", %{})
      |> Map.put("lifecycle", "finished")
      |> Map.update!("members", fn members ->
        Enum.map(members, &Map.merge(&1, %{"generation" => 999, "left" => true}))
      end)

    restored = Authority.restore(Map.put(row, "state_json", corrupted))
    assert restored["content"] == original["content"]
    assert restored["items"] == original["items"]
    assert restored["lifecycle"] == original["lifecycle"]
    assert restored["members"] == original["members"]
    assert DB.str(row["id"]) == room["room_id"]
  end
end
