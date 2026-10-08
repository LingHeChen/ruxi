defmodule Ruxi.Privacy do
  use GenServer
  @moduledoc "Account tombstones and an independently persisted erasure ledger."
  alias Ruxi.{Auth, DB, Util, Store, Retention}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: {:ok, replay()}

  def ledger_path,
    do:
      System.get_env(
        "ERASURE_LEDGER_PATH",
        Path.expand("../../.local/erasure-ledger.jsonl", File.cwd!())
      )

  def erase(ctx, p) do
    RuxiWeb.Router.json!(p, ~w(command_id confirmation))

    Util.require!(
      Ruxi.Contract.uuid?(p["command_id"]) and p["confirmation"] == "ERASE_ACCOUNT",
      "INVALID_ARGUMENT"
    )

    result =
      DB.transaction(fn ->
        DB.query("SELECT id FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(ctx.user)])
        Auth.valid!(ctx)
        # Persist intent before committing deletion. A failed transaction can be
        # safely replayed from the ledger before restored service accepts traffic.
        :ok =
          append(%{
            "schema" => 1,
            "user_id" => ctx.user,
            "erased_at" => DB.time(),
            "request_id" => p["command_id"]
          })

        apply!(ctx.user)
        %{"erased" => true, "requires_new_identity" => true}
      end)

    if match?({:ok, _}, result) do
      for row <- DB.rows("SELECT id FROM sessions WHERE user_id=$1", [DB.uuid(ctx.user)]),
          do: RuxiWeb.Endpoint.broadcast("session:#{DB.str(row["id"])}", "disconnect", %{})
    end

    result
  end

  def append(record) do
    :global.trans({__MODULE__, self()}, fn ->
      path = ledger_path()
      File.mkdir_p!(Path.dirname(path))
      {:ok, file} = :file.open(String.to_charlist(path), [:append, :binary, :raw, :sync])
      File.chmod!(path, 0o600)

      try do
        :ok = :file.write(file, Jason.encode!(record) <> "\n")
        :ok = :file.sync(file)
      after
        :file.close(file)
      end
    end)
  end

  def replay do
    case File.stat(ledger_path()) do
      {:error, :enoent} ->
        %{"replayed" => 0}

      {:ok, %{size: size}} when size <= 67_108_864 ->
        users =
          File.stream!(ledger_path())
          |> Enum.map(fn line ->
            record = Jason.decode!(line)

            Util.require!(
              record["schema"] == 1 and Ruxi.Contract.uuid?(record["user_id"]) and
                is_integer(record["erased_at"]),
              "INVALID_ARGUMENT"
            )

            record["user_id"]
          end)
          |> Enum.uniq()

        for user <- users, do: DB.transaction(fn -> apply!(user) end) |> replay_result!()
        %{"replayed" => length(users)}

      _ ->
        raise "erasure ledger unavailable or requires rotation"
    end
  end

  defp replay_result!({:ok, _}), do: :ok
  defp replay_result!(_), do: raise("erasure replay failed")

  def apply!(user) do
    row = DB.one("SELECT status FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(user)])
    if row && row["status"] == "erased", do: %{"rooms_scrubbed" => 0}, else: scrub!(user)
  end

  defp scrub!(user) do
    uid = DB.uuid(user)

    DB.query(
      "INSERT INTO users(id,display_name,status) VALUES($1,'已注销玩家','erased') ON CONFLICT(id) DO NOTHING",
      [uid]
    )

    DB.query("SELECT id FROM users WHERE id=$1 FOR UPDATE", [uid])

    DB.query(
      "UPDATE users SET status='erased',display_name='已注销玩家',recovery_hash=NULL,recovery_generation=recovery_generation+1 WHERE id=$1",
      [uid]
    )

    DB.query("UPDATE sessions SET revoked=true WHERE user_id=$1", [uid])

    DB.query(
      "DELETE FROM socket_tickets WHERE session_id IN (SELECT id FROM sessions WHERE user_id=$1)",
      [uid]
    )

    DB.query("DELETE FROM account_commands WHERE user_id=$1", [uid])
    DB.query("DELETE FROM telemetry_events WHERE user_id=$1", [uid])

    DB.query(
      "UPDATE chat_reports SET reporter_user_id=NULL,sender_member_id=NULL,message_text=NULL WHERE reporter_user_id=$1 OR sender_member_id IN (SELECT id FROM room_members WHERE user_id=$1)",
      [uid]
    )

    DB.query("DELETE FROM admin_roles WHERE user_id=$1", [uid])
    DB.query("DELETE FROM admin_login_codes WHERE user_id=$1", [uid])

    rooms =
      DB.rows("SELECT DISTINCT room_id FROM room_members WHERE user_id=$1 ORDER BY room_id", [uid])

    affected_jobs =
      Enum.flat_map(rooms, fn r ->
        DB.rows("SELECT id FROM work_items WHERE room_id=$1", [r["room_id"]])
      end)
      |> MapSet.new(&DB.str(&1["id"]))

    # Short-lived encrypted retry copies are part of the erasure scope too.
    for row <- DB.rows("SELECT scope,key_hash,response_ciphertext FROM auth_retry_cache") do
      if Auth.unseal(row["response_ciphertext"])["user_id"] == user,
        do:
          DB.query("DELETE FROM auth_retry_cache WHERE scope=$1 AND key_hash=$2", [
            row["scope"],
            row["key_hash"]
          ])
    end

    for row <- DB.rows("SELECT worker_id,claim_id,reply_ciphertext FROM work_claims") do
      if MapSet.member?(affected_jobs, Auth.unseal(row["reply_ciphertext"])["job_id"]),
        do:
          DB.query("DELETE FROM work_claims WHERE worker_id=$1 AND claim_id=$2", [
            row["worker_id"],
            row["claim_id"]
          ])
    end

    for room <- rooms do
      old = Store.load!(DB.str(room["room_id"]), true)["state_json"]
      now = DB.time()

      members =
        Enum.map(old["members"], fn m ->
          m = Map.merge(m, %{"hints" => [], "hint_pending" => nil})

          if m["user_id"] == user,
            do:
              Map.merge(m, %{
                "name" => "已注销玩家",
                "online" => false,
                "left" => true,
                "device" => nil,
                "generation" => m["generation"] + 1,
                "offline_at" => now
              }),
            else: m
        end)

      new = Map.merge(old, %{"members" => members, "chat" => []})

      new =
        if old["lifecycle"] in ~w(finished abandoned) or old["phase"] == "ending",
          do: new,
          else:
            Map.merge(new, %{
              "lifecycle" => "abandoned",
              "deadline" => nil,
              "pause_request" => nil,
              "role_swap" => nil,
              "offers" =>
                Enum.map(
                  new["offers"],
                  &Map.put(
                    &1,
                    "status",
                    if(&1["status"] == "pending", do: "cancelled", else: &1["status"])
                  )
                )
            })

      Store.save(old, new, "lifecycle_changed", now)
      Retention.discard_history(room["room_id"])
      DB.query("DELETE FROM room_commands WHERE room_id=$1", [room["room_id"]])

      DB.query(
        "UPDATE work_items SET input_json='{}',result_json=NULL,result_hash=NULL,completion_response_json=NULL,status='failed',lease_hash=NULL,lease_until=NULL WHERE room_id=$1",
        [room["room_id"]]
      )
    end

    DB.query(
      "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,'account.erase',$2,$3)",
      [DB.uuid(Util.id()), uid, DB.time()]
    )

    %{"rooms_scrubbed" => length(rooms)}
  end
end
