defmodule Ruxi.Maintenance do
  use Oban.Worker, queue: :maintenance, max_attempts: 5, unique: [period: 55]
  alias Ruxi.DB
  @impl Oban.Worker
  def perform(_job) do
    run()
    Ruxi.Retention.run()
    :ok
  end

  def run do
    DB.transaction(fn ->
      now = DB.time()
      # Inactive rooms have no resident timer process. Expire their durable facts
      # without waking every historical room once per second.
      rooms =
        DB.rows(
          "SELECT * FROM rooms WHERE (owner_instance IS NULL OR lease_until <= $1) AND ((lifecycle='suspended' AND (state_json->>'suspended_at')::bigint <= $2) OR (lifecycle='lobby' AND deadline_at <= $1)) LIMIT 100 FOR UPDATE SKIP LOCKED",
          [now, now - 86_400_000]
        )

      for room <- rooms do
        old = room["state_json"]
        new = Ruxi.Rules.tick(old, now)
        if new != old, do: Ruxi.Store.save(old, new, "lifecycle_changed", now)
      end

      # Source upload deadlines are independent of the Worker lease.
      DB.query(
        "UPDATE assets SET status='quarantined',error_code='UPLOAD_EXPIRED' WHERE id IN (SELECT id FROM assets WHERE status='uploading' AND upload_expires_at <= $1 LIMIT 100 FOR UPDATE SKIP LOCKED)",
        [now]
      )

      rows =
        DB.rows(
          "SELECT id,basis FROM work_items WHERE room_id IS NULL AND status='leased' AND lease_until <= $1 AND attempt >= 3 ORDER BY created_at LIMIT 100",
          [now]
        )

      for row <- rows do
        # Same asset/version -> job order as completion; reevaluate after locking.
        if row["basis"]["asset_id"] do
          DB.query("SELECT id FROM assets WHERE id=$1 FOR UPDATE", [
            DB.uuid(row["basis"]["asset_id"])
          ])
        else
          DB.query("SELECT id FROM content_versions WHERE id=$1 FOR UPDATE", [
            DB.uuid(row["basis"]["version_id"])
          ])
        end

        changed =
          DB.query(
            "UPDATE work_items SET status='failed',lease_hash=NULL,lease_until=NULL WHERE id=$1 AND status='leased' AND lease_until <= $2 AND attempt >= 3",
            [row["id"], now]
          )

        if changed.num_rows > 0 and row["basis"]["asset_id"],
          do:
            DB.query(
              "UPDATE assets SET status='quarantined',error_code='WORKER_RETRY_EXHAUSTED' WHERE id=$1 AND status='processing'",
              [DB.uuid(row["basis"]["asset_id"])]
            )
      end

      DB.query(
        "UPDATE work_items SET input_json='{}',result_json=NULL,completion_response_json=NULL WHERE id IN (SELECT id FROM work_items WHERE room_id IS NULL AND status IN ('completed','failed') AND created_at <= $1 LIMIT 100)",
        [now - 7 * 86_400_000]
      )

      candidates =
        DB.rows(
          "SELECT id,kind,basis,attempt FROM work_items WHERE room_id IS NULL AND status IN ('completed','failed') AND created_at <= $1 AND objects_purged_at IS NULL ORDER BY created_at LIMIT 100 FOR UPDATE SKIP LOCKED",
          [now - 7 * 86_400_000]
        )

      for j <- candidates do
        keep =
          if j["kind"] == "media_transcode" do
            a =
              DB.one("SELECT outputs FROM assets WHERE id=$1", [DB.uuid(j["basis"]["asset_id"])])

            if a && is_map(a["outputs"]),
              do: Enum.map(Map.values(a["outputs"]), & &1["object_key"]),
              else: []
          else
            []
          end

        for attempt <- 1..max(1, j["attempt"]),
            kind <- ~w(video.mp4 poster.jpg subtitle.vtt proposal.json) do
          key = "ruxi/jobs/#{DB.str(j["id"])}/#{attempt}/#{kind}"
          unless key in keep, do: File.rm(Ruxi.Objects.path(key))
        end

        DB.query("UPDATE work_items SET objects_purged_at=$2 WHERE id=$1", [j["id"], now])
      end

      DB.query("DELETE FROM room_summaries WHERE terminal_at <= $1", [now - 180 * 86_400_000])
      %{"expired_jobs" => length(rows)}
    end)
  end
end

defmodule Ruxi.Operations do
  alias Ruxi.{Auth, DB}

  def report(ctx) do
    Auth.role!(ctx, "reviewer")

    %{
      "rooms" => DB.rows("SELECT lifecycle,count(*) AS count FROM rooms GROUP BY lifecycle"),
      "work" =>
        DB.rows("SELECT kind,status,count(*) AS count FROM work_items GROUP BY kind,status"),
      "outbox_pending" =>
        DB.one("SELECT count(*) AS count FROM outbox WHERE delivered_at IS NULL")["count"],
      "oldest_outbox_age_ms" =>
        DB.one(
          "SELECT COALESCE(GREATEST(0,$1-min((extract(epoch from (e.event_json->>'occurred_at')::timestamptz)*1000)::bigint)),0)::bigint AS age FROM outbox o JOIN member_view_events e USING(room_id,member_id,seq) WHERE o.delivered_at IS NULL",
          [DB.time()]
        )["age"],
      "outcomes" =>
        DB.rows(
          "SELECT content_version_id::text AS content_version_id,lifecycle,ending_code,count(*) AS count FROM room_summaries GROUP BY content_version_id,lifecycle,ending_code"
        ),
      "runtime" => %{
        "processes" => :erlang.system_info(:process_count),
        "memory_bytes" => :erlang.memory(:total)
      },
      "scope" => "Committed server facts; no player identities, chat, hints or votes."
    }
  end
end
