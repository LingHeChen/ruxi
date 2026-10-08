defmodule Ruxi.Recovery do
  @moduledoc "Offline-only recovery fence, executed before the public application starts."
  alias Ruxi.{DB, Util}

  def reset! do
    unless System.get_env("RECOVERY_CONFIRMATION") == "RESET_RESTORED_DATABASE",
      do: raise("RECOVERY_CONFIRMATION must identify an isolated restored database")

    if Process.whereis(RuxiWeb.Endpoint), do: raise("public application must be stopped")
    if byte_size(Util.epoch()) < 16, do: raise("configure a new recovery epoch")

    DB.transaction(fn ->
      old =
        DB.rows(
          "SELECT DISTINCT event_json->>'recovery_epoch' AS epoch FROM member_view_events LIMIT 100"
        )

      if Enum.any?(old, &(&1["epoch"] == Util.epoch())), do: raise("recovery epoch must change")
      DB.query("UPDATE sessions SET revoked=true,revoked_at=$1", [DB.time()])

      for table <- ~w(socket_tickets consumed_refresh auth_retry_cache work_claims),
          do: DB.query("DELETE FROM #{table}")

      DB.query(
        "UPDATE work_items SET status='queued',lease_hash=NULL,lease_until=NULL,leased_by=NULL WHERE status='leased'"
      )

      DB.query("UPDATE rooms SET owner_instance=NULL,lease_until=0,owner_epoch=owner_epoch+1")

      DB.query(
        "UPDATE room_members SET replay_floor_seq=view_seq,control_generation=control_generation+1,device_id=NULL"
      )

      DB.query("TRUNCATE TABLE outbox,member_view_events")
      DB.query("DELETE FROM room_commands")
      # Body state must agree with SQL generations; next startup reconstructs presence.
      for room <- DB.rows("SELECT id,state_json FROM rooms FOR UPDATE") do
        state =
          Map.update!(room["state_json"], "members", fn members ->
            Enum.map(
              members,
              &Map.merge(&1, %{
                "online" => false,
                "device" => nil,
                "generation" => &1["generation"] + 1,
                "offline_at" => DB.time()
              })
            )
          end)

        DB.query("UPDATE rooms SET state_json=$2 WHERE id=$1", [room["id"], state])
      end

      %{
        "recovery_epoch" => Util.epoch(),
        "sessions_revoked" => true,
        "owners_fenced" => true,
        "old_projections_discarded" => true
      }
    end)
  end
end
