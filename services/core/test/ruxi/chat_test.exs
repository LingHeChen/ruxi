defmodule Ruxi.ChatTest do
  use ExUnit.Case
  alias Ruxi.{Auth, DB, Util, Store, Chat}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Ruxi.Content.seed()
    device = Util.id()
    {:ok, auth} = Auth.guest(%{"device_id" => device, "command_id" => Util.id()})
    ctx = Auth.authenticate(auth["access_token"])

    {:ok, room} =
      Auth.create_room(ctx, %{"story_id" => Ruxi.Content.story_id(), "command_id" => Util.id()})

    {:ok, ticket} =
      Auth.ticket(ctx, room["room_id"], %{"device_id" => device, "takeover" => false})

    ctx = Auth.member_context(ctx, room["room_id"], device, ticket["control_generation"])
    old = Store.load!(ctx.room)["state_json"]

    message = %{
      "message_id" => Util.id(),
      "sender_member" => ctx.member,
      "text" => "讨论片段",
      "sent_at" => Util.iso(Util.now())
    }

    DB.transaction(fn ->
      Store.save(old, Map.put(old, "chat", [message]), "chat_added", DB.time())
    end)

    %{ctx: ctx, message: message}
  end

  test "text policy preserves ordinary discussion and rejects control and disguised abuse" do
    assert Chat.text!("  第一条线索\n继续调查  ") == "第一条线索\n继续调查"
    assert catch_throw(Chat.text!("不支持\x00字符")) == {:error, "CHAT_REJECTED"}
    assert catch_throw(Chat.text!("傻\u200B逼")) == {:error, "CHAT_REJECTED"}
  end

  test "reports use authorized stored text, deduplicate and reject invented messages", %{
    ctx: ctx,
    message: message
  } do
    payload = %{
      "message_id" => message["message_id"],
      "reason" => "privacy",
      "command_id" => Util.id()
    }

    assert {:ok, a} = Chat.report(ctx, payload)
    assert {:ok, ^a} = Chat.report(ctx, payload)
    replaced = %{ctx | generation: ctx.generation + 1}
    assert {:error, "CONTROL_REPLACED"} = Chat.report(replaced, payload)
    assert {:ok, b} = Chat.report(ctx, Map.put(payload, "command_id", Util.id()))
    assert a == b

    assert DB.one("SELECT message_text FROM chat_reports WHERE id=$1", [DB.uuid(a["report_id"])])[
             "message_text"
           ] == message["text"]

    assert {:error, "RESOURCE_NOT_FOUND"} =
             Chat.report(
               ctx,
               Map.merge(payload, %{"message_id" => Util.id(), "command_id" => Util.id()})
             )
  end

  test "review requires reviewer permission and persists an audit", %{ctx: ctx, message: message} do
    {:ok, report} =
      Chat.report(ctx, %{
        "message_id" => message["message_id"],
        "reason" => "spam",
        "command_id" => Util.id()
      })

    assert catch_throw(Chat.queue(ctx)) == {:error, "NOT_ALLOWED"}
    DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,'reviewer')", [DB.uuid(ctx.user)])
    auth = Auth.session(ctx.user, Util.id(), "admin")
    admin = Auth.authenticate(auth["access_token"], "admin")
    assert length(Chat.queue(admin)["items"]) == 1
    p = %{"command_id" => Util.id(), "status" => "resolved"}
    assert {:ok, %{"status" => "resolved"}} = Chat.review(admin, report["report_id"], p)
    assert {:ok, %{"status" => "resolved"}} = Chat.review(admin, report["report_id"], p)

    assert DB.one(
             "SELECT count(*) AS n FROM audit_log WHERE operation='chat.report.review' AND target_id=$1",
             [DB.uuid(report["report_id"])]
           )["n"] == 1
  end
end
