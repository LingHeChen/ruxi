defmodule Ruxi.Chat do
  alias Ruxi.{Util, DB, Auth, Store}

  def text!(text) do
    normalized = text |> String.trim() |> String.replace(~r/[\x{200B}-\x{200D}\x{FEFF}]/u, "")
    words = Application.get_env(:ruxi, :chat_blocklist, ["傻逼", "操你妈", "去死"])

    Util.require!(
      not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, normalized) and
        not Enum.any?(words, &String.contains?(normalized, &1)) and
        String.length(normalized) in 1..500,
      "CHAT_REJECTED"
    )

    normalized
  end

  def report(ctx, p) do
    RuxiWeb.Router.json!(p, ~w(message_id reason command_id))

    Util.require!(
      Ruxi.Contract.uuid?(p["message_id"]) and p["reason"] in ~w(harassment privacy spam other),
      "INVALID_ARGUMENT"
    )

    Ruxi.Limiter.check!({:report, ctx.user}, 0.1, 5)

    Auth.account(ctx, "chat.report", Map.put(p, "room_id", ctx.room), fn ->
      state = Store.load!(ctx.room, true)["state_json"]
      Store.auth!(state, ctx)
      message = Enum.find(state["chat"], &(&1["message_id"] == p["message_id"]))
      Util.require!(message != nil, "RESOURCE_NOT_FOUND")
      id = Util.id()

      row =
        DB.one(
          """
          INSERT INTO chat_reports(id,room_id,reporter_user_id,sender_member_id,message_id,message_text,reason)
          VALUES($1,$2,$3,$4,$5,$6,$7)
          ON CONFLICT(reporter_user_id,room_id,message_id) DO UPDATE SET id=chat_reports.id RETURNING id
          """,
          [
            DB.uuid(id),
            DB.uuid(ctx.room),
            DB.uuid(ctx.user),
            DB.uuid(message["sender_member"]),
            DB.uuid(p["message_id"]),
            message["text"],
            p["reason"]
          ]
        )

      %{"report_id" => DB.str(row["id"]), "status" => "received"}
    end)
  end

  def queue(ctx) do
    Auth.role!(ctx, "reviewer")

    %{
      "items" =>
        DB.rows(
          "SELECT id,reason,status,message_text,created_at FROM chat_reports WHERE status='open' ORDER BY created_at,id LIMIT 100"
        )
        |> Enum.map(fn r -> r |> Map.put("report_id", DB.str(r["id"])) |> Map.delete("id") end)
    }
  end

  def review(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(command_id status), ~w(remove_message))
    Auth.role!(ctx, "reviewer")
    Util.require!(p["status"] in ~w(resolved dismissed), "INVALID_ARGUMENT")
    remove = Map.get(p, "remove_message", false)

    Util.require!(
      is_boolean(remove) and (not remove or p["status"] == "resolved"),
      "INVALID_ARGUMENT"
    )

    Auth.account(ctx, "chat.report.review", Map.put(p, "report_id", id), fn ->
      report = DB.one("SELECT room_id,message_id FROM chat_reports WHERE id=$1", [DB.uuid(id)])
      Util.require!(report != nil, "RESOURCE_NOT_FOUND")
      state = if remove, do: Store.load!(DB.str(report["room_id"]), true)["state_json"], else: nil

      row =
        DB.one(
          "UPDATE chat_reports SET status=$2,reviewed_at=clock_timestamp() WHERE id=$1 AND status='open' RETURNING id",
          [DB.uuid(id), p["status"]]
        )

      Util.require!(row != nil, "RESOURCE_NOT_FOUND")

      if remove do
        updated =
          Map.update!(state, "chat", fn messages ->
            Enum.reject(messages, &(&1["message_id"] == DB.str(report["message_id"])))
          end)

        Store.save(state, updated, "chat_added", DB.time())
        Ruxi.Retention.discard_history(report["room_id"])
      end

      DB.query(
        "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,'chat.report.review',$3,$4)",
        [DB.uuid(Util.id()), DB.uuid(ctx.user), DB.uuid(id), DB.time()]
      )

      %{"report_id" => id, "status" => p["status"]}
    end)
  end
end
