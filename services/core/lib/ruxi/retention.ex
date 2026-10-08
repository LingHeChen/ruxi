defmodule Ruxi.Retention do
  @moduledoc "Bounded, transactional retention; active and suspended rooms are never age-purged."
  use GenServer
  require Logger
  alias Ruxi.{DB, Store}
  @day 86_400_000
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :clean, 900_000)
    {:ok, nil}
  end

  def handle_info(:clean, state) do
    try do
      run()
    rescue
      _ -> Logger.warning("retention batch failed; retrying on the next scheduled batch")
    end

    Process.send_after(self(), :clean, 900_000)
    {:noreply, state}
  end

  def run(now \\ nil) do
    DB.transaction(fn ->
      now = now || DB.time()

      rows =
        DB.rows(
          "SELECT * FROM rooms WHERE lifecycle IN ('finished','abandoned') AND terminal_at <= $1 AND (bodies_purged_at IS NULL OR terminal_at <= $2) ORDER BY terminal_at,id LIMIT 20 FOR UPDATE SKIP LOCKED",
          [now - 7 * @day, now - 180 * @day]
        )

      for row <- rows do
        rid = row["id"]
        discard_history(rid)

        if row["terminal_at"] <= now - 180 * @day do
          delete_room(rid)
        else
          old = row["state_json"]

          new =
            old
            |> Map.put("terminal_at", row["terminal_at"])
            |> Map.put("chat", [])
            |> Map.update!("members", fn ms ->
              Enum.map(ms, &Map.merge(&1, %{"hints" => [], "hint_pending" => nil}))
            end)

          Store.save(old, new, "lifecycle_changed", now)
          # Advance the watermark and floor together: connected clients repair with
          # a fresh scrubbed snapshot, and no removal event is retained past 7d.
          discard_history(rid)
          DB.query("UPDATE rooms SET bodies_purged_at=$2 WHERE id=$1", [rid, now])

          DB.query("UPDATE work_items SET input_json='{}',result_json=NULL WHERE room_id=$1", [
            rid
          ])

          DB.query("DELETE FROM room_commands WHERE room_id=$1", [rid])
        end
      end

      DB.query("DELETE FROM account_commands WHERE created_at<=$1", [now - 30 * @day])
      DB.query("DELETE FROM auth_retry_cache WHERE expires_at<=$1", [now])
      DB.query("DELETE FROM work_claims WHERE expires_at<=$1", [now])
      DB.query("DELETE FROM socket_tickets WHERE expires_at<=$1", [now - @day])
      DB.query("DELETE FROM admin_login_codes WHERE expires_at<=$1", [now - @day])

      expired =
        DB.rows(
          "SELECT id FROM sessions WHERE family_expires_at<=$1 OR (revoked AND revoked_at<=$1) ORDER BY id LIMIT 200",
          [now - 7 * @day]
        )

      for s <- expired do
        DB.query("DELETE FROM socket_tickets WHERE session_id=$1", [s["id"]])
        DB.query("DELETE FROM consumed_refresh WHERE session_id=$1", [s["id"]])
        DB.query("DELETE FROM sessions WHERE id=$1", [s["id"]])
      end

      DB.query("DELETE FROM audit_log WHERE occurred_at<=$1", [now - 180 * @day])

      DB.query(
        "UPDATE chat_reports SET message_text=NULL WHERE id IN (SELECT id FROM chat_reports WHERE created_at <= $1 AND message_text IS NOT NULL ORDER BY created_at LIMIT 1000)",
        [DateTime.from_unix!(now - 30 * @day, :millisecond)]
      )

      DB.query(
        "DELETE FROM chat_reports WHERE id IN (SELECT id FROM chat_reports WHERE created_at <= $1 ORDER BY created_at LIMIT 1000)",
        [DateTime.from_unix!(now - 180 * @day, :millisecond)]
      )

      DB.query(
        "DELETE FROM telemetry_events WHERE event_id IN (SELECT event_id FROM telemetry_events WHERE received_at <= $1 ORDER BY received_at LIMIT 1000)",
        [DateTime.from_unix!(now - 7 * @day, :millisecond)]
      )

      %{"rooms_processed" => length(rows), "sessions_removed" => length(expired)}
    end)
  end

  def discard_history(rid) do
    n =
      DB.one("SELECT count(*) AS n FROM outbox WHERE room_id=$1 AND delivered_at IS NULL", [rid])[
        "n"
      ]

    if n > 0, do: Logger.warning("retention terminates #{n} expired outbox deliveries")
    DB.query("UPDATE room_members SET replay_floor_seq=view_seq WHERE room_id=$1", [rid])
    DB.query("DELETE FROM outbox WHERE room_id=$1", [rid])
    DB.query("DELETE FROM member_view_events WHERE room_id=$1", [rid])
  end

  defp delete_room(rid) do
    for table <-
          ~w(socket_tickets work_items room_commands votes vote_settlements vote_rounds item_offers room_items room_members),
        do: DB.query("DELETE FROM #{table} WHERE room_id=$1", [rid])

    DB.query("DELETE FROM rooms WHERE id=$1", [rid])
  end
end
