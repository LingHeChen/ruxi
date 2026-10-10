defmodule Ruxi.SceneVoice.Maintenance do
  use GenServer
  alias Ruxi.{DB, Repo}
  alias Ruxi.SceneVoice.Coordinator
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    if Application.get_env(:ruxi, :voice_maintenance, true),
      do: Process.send_after(self(), :scan, 1000)

    {:ok, state}
  end

  def handle_info(:scan, running) do
    next =
      try do
        Repo.checkout(fn ->
          if DB.one("SELECT to_regclass('ruxi.c2_voice_transitions') IS NOT NULL AS ready")[
               "ready"
             ] do
            rooms =
              DB.rows(
                "SELECT DISTINCT room_id FROM (SELECT t.room_id FROM c2_voice_transitions t JOIN c2_rooms r ON r.id=t.room_id WHERE t.phase IN ('retiring','blocked') AND (r.owner_id=$1 OR r.lease_until IS NULL OR r.lease_until<$2) UNION SELECT room_id FROM c2_voice_revocations WHERE phase='pending') jobs LIMIT 32",
                [Application.get_env(:ruxi, :core_instance, "local-core"), DB.time()]
              )

            available = max(0, 4 - map_size(running))

            rooms
            |> Enum.reject(&(&1["room_id"] in Map.values(running)))
            |> Enum.take(available)
            |> Enum.reduce(running, fn row, tasks ->
              room = row["room_id"]

              task =
                Task.Supervisor.async_nolink(Ruxi.VoiceTasks, fn ->
                  try do
                    Repo.checkout(fn ->
                      Coordinator.recover(DB.str(room))
                      Ruxi.C2.Store.tick(DB.str(room))
                    end)
                  catch
                    {:error, _} -> :retry
                  end
                end)

              Map.put(tasks, task.ref, room)
            end)
          else
            running
          end
        end)
      rescue
        _ in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
          running
      end

    Process.send_after(self(), :scan, 1000)
    {:noreply, next}
  end

  def handle_info({ref, _}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, Map.delete(state, ref)}
  end

  def handle_info({:DOWN, ref, _, _, _}, state), do: {:noreply, Map.delete(state, ref)}
end
