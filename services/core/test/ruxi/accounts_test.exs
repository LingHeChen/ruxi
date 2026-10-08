defmodule Ruxi.AccountsTest do
  use ExUnit.Case
  alias Ruxi.{Accounts, Auth, Catalog, Content, DB, Util}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Content.seed()

    %{
      params: %{
        "username" => "player_" <> String.slice(Util.id(), 0, 8),
        "password" => "a-strong-password-2026",
        "display_name" => "新玩家",
        "device_id" => Util.id(),
        "command_id" => Util.id()
      }
    }
  end

  def login(params, password \\ nil),
    do:
      Accounts.login(%{
        "username" => String.upcase(params["username"]),
        "password" => password || params["password"],
        "device_id" => Util.id(),
        "login_request_id" => Util.id()
      })

  test "registration stores a salted password digest and retry preserves identity", %{params: p} do
    assert {:ok, auth} = Accounts.register(p)
    assert {:ok, ^auth} = Accounts.register(p)

    row =
      DB.one("SELECT password_hash FROM player_accounts WHERE user_id=$1", [
        DB.uuid(auth["user_id"])
      ])

    assert String.starts_with?(row["password_hash"], "pbkdf2-sha256$600000$")
    refute row["password_hash"] =~ p["password"]
    assert {:ok, other} = login(p)
    assert auth["user_id"] == other["user_id"]
    assert Accounts.profile(Auth.authenticate(other["access_token"]))["is_guest"] == false
  end

  test "wrong password and nonexistent account reject authentication", %{params: p} do
    Accounts.register(p)
    assert {:error, "UNAUTHORIZED"} = login(p, "not-the-password")
    assert {:error, "UNAUTHORIZED"} = login(Map.put(p, "username", "nonexistent"))
    assert {:error, "USERNAME_TAKEN"} = Accounts.register(Map.put(p, "command_id", Util.id()))
  end

  test "upgrade keeps the guest user, membership and favorites", %{params: p} do
    {:ok, g} = Auth.guest(%{"device_id" => p["device_id"], "command_id" => Util.id()})
    ctx = Auth.authenticate(g["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Content.story_id(), "command_id" => Util.id()})

    Catalog.favorite(ctx, Content.story_id(), %{"saved" => true, "command_id" => Util.id()})
    {:ok, registered} = Accounts.register(p, ctx)
    assert registered["user_id"] == g["user_id"]
    assert hd(Catalog.rooms(ctx)["items"])["room_id"] == room["room_id"]
    assert length(Catalog.favorites(ctx)["items"]) == 1

    assert {:error, "ALREADY_REGISTERED"} =
             Accounts.register(
               Map.merge(p, %{"username" => "another-account", "command_id" => Util.id()}),
               ctx
             )
  end

  test "profile edits are owned and idempotent; passwords revoke all sessions", %{params: p} do
    {:ok, a} = Accounts.register(p)
    {:ok, b} = login(p)
    ctx = Auth.authenticate(a["access_token"])
    edit = %{"display_name" => "新昵称", "bio" => "爱悬疑", "command_id" => Util.id()}
    assert {:ok, result} = Accounts.update(ctx, edit)
    assert result["display_name"] == "新昵称"
    assert result["bio"] == "爱悬疑"
    assert {:ok, ^result} = Accounts.update(ctx, edit)

    assert {:error, "UNAUTHORIZED"} =
             Accounts.change_password(ctx, %{
               "current_password" => "bad-password",
               "new_password" => "new-password-strong",
               "command_id" => Util.id()
             })

    assert {:ok, %{"changed" => true}} =
             Accounts.change_password(ctx, %{
               "current_password" => p["password"],
               "new_password" => "new-password-strong",
               "command_id" => Util.id()
             })

    assert catch_throw(Auth.authenticate(a["access_token"])) == {:error, "UNAUTHORIZED"}
    assert catch_throw(Auth.authenticate(b["access_token"])) == {:error, "UNAUTHORIZED"}
    assert {:error, "UNAUTHORIZED"} = login(p)
    assert {:ok, _} = login(p, "new-password-strong")
  end

  test "ordinary registered users cannot obtain admin sessions", %{params: p} do
    {:ok, a} = Accounts.register(p)

    payload = %{
      "username" => p["username"],
      "password" => p["password"],
      "device_id" => p["device_id"],
      "login_request_id" => Util.id()
    }

    assert {:error, "NOT_ALLOWED"} = Accounts.login(payload, "admin")

    DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,'reviewer')", [
      DB.uuid(a["user_id"])
    ])

    assert {:ok, admin} = Accounts.login(Map.put(payload, "login_request_id", Util.id()), "admin")
    assert admin["roles"] == ["reviewer"]
    assert Auth.authenticate(admin["access_token"], "admin").audience == "admin"
    assert catch_throw(Auth.authenticate(admin["access_token"])) == {:error, "NOT_ALLOWED"}
  end

  test "public search/category/seat filters match SQL and hide unavailable details", %{params: p} do
    {:ok, a} = Accounts.register(p)
    ctx = Auth.authenticate(a["access_token"])
    DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,'editor')", [DB.uuid(ctx.user)])
    assert Catalog.list(%{"q" => "末班车"})["total"] == 1
    assert Catalog.list(%{"q" => "不存在"})["items"] == []
    assert Catalog.list(%{"seats" => "4"})["items"] == []

    assert {:ok, _} =
             Catalog.metadata(ctx, Content.story_id(), %{
               "category" => "scifi",
               "difficulty" => "advanced",
               "summary" => "新的科幻简介",
               "command_id" => Util.id()
             })

    assert Catalog.list(%{"category" => "mystery"})["items"] == []

    assert hd(Catalog.list(%{"category" => "scifi", "q" => "科幻"})["items"])["difficulty"] ==
             "advanced"

    DB.query("UPDATE content_versions SET availability='unavailable' WHERE id=$1", [
      DB.uuid(Content.version_id())
    ])

    assert catch_throw(Catalog.detail(Content.story_id())) == {:error, "RESOURCE_NOT_FOUND"}
  end

  test "favorites are private and deletion removes credentials and favorites", %{params: p} do
    {:ok, a} = Accounts.register(p)
    ctx = Auth.authenticate(a["access_token"])
    {:ok, b} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    other = Auth.authenticate(b["access_token"])
    payload = %{"saved" => true, "command_id" => Util.id()}
    assert {:ok, %{"saved" => true}} = Catalog.favorite(ctx, Content.story_id(), payload)
    assert {:ok, %{"saved" => true}} = Catalog.favorite(ctx, Content.story_id(), payload)
    assert length(Catalog.favorites(ctx)["items"]) == 1
    assert Catalog.favorites(other)["items"] == []
    assert {:ok, _} = DB.transaction(fn -> Ruxi.Privacy.apply!(ctx.user) end)

    assert DB.one("SELECT user_id FROM player_accounts WHERE user_id=$1", [DB.uuid(ctx.user)]) ==
             nil

    assert DB.one("SELECT user_id FROM story_favorites WHERE user_id=$1", [DB.uuid(ctx.user)]) ==
             nil

    assert {:error, "UNAUTHORIZED"} = login(p)
  end

  test "recovery code resets password once, rotates code and invalidates old sessions", %{
    params: p
  } do
    {:ok, auth} = Accounts.register(p)

    reset = %{
      "recovery_code" => auth["recovery_code"],
      "new_password" => "recovered-password",
      "device_id" => Util.id(),
      "recovery_request_id" => Util.id()
    }

    assert {:ok, restored} = Accounts.reset_password(reset)
    assert {:ok, ^restored} = Accounts.reset_password(reset)
    refute restored["recovery_code"] == auth["recovery_code"]
    assert catch_throw(Auth.authenticate(auth["access_token"])) == {:error, "UNAUTHORIZED"}

    assert {:error, "UNAUTHORIZED"} =
             Accounts.reset_password(Map.put(reset, "recovery_request_id", Util.id()))

    assert {:error, "UNAUTHORIZED"} = login(p)
    assert {:ok, _} = login(p, "recovered-password")
  end

  test "publisher grants scoped admin roles; ordinary users cannot grant roles", %{params: p} do
    {:ok, a} = Accounts.register(p)
    actor = Auth.authenticate(a["access_token"])

    {:ok, b} =
      Accounts.register(
        Map.merge(p, %{"username" => "second-account", "command_id" => Util.id()})
      )

    command = %{"roles" => ["reviewer"], "command_id" => Util.id()}

    assert catch_throw(Accounts.assign_roles(actor, b["user_id"], command)) ==
             {:error, "NOT_ALLOWED"}

    DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,'publisher')", [DB.uuid(actor.user)])

    assert {:ok, %{"roles" => ["reviewer"]}} = Accounts.assign_roles(actor, b["user_id"], command)
    assert Auth.roles(b["user_id"]) == ["reviewer"]

    assert catch_throw(
             Accounts.assign_roles(actor, actor.user, %{"roles" => [], "command_id" => Util.id()})
           ) == {:error, "INVALID_ARGUMENT"}
  end
end
