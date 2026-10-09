defmodule Ruxi.C2.Maintenance do
  use GenServer
  alias Ruxi.{DB, Repo}
  alias Ruxi.C2.Store
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    if Application.get_env(:ruxi, :c2_maintenance, true),
      do: Process.send_after(self(), :tick, 1000)

    {:ok, nil}
  end

  def handle_info(:tick, state) do
    try do
      Repo.checkout(fn ->
        # Migrations may run after the release boots. Retry without blocking C1.
        if DB.one("SELECT to_regclass('ruxi.c2_rooms') IS NOT NULL AS ready")["ready"] do
          for r <-
                DB.rows(
                  "SELECT id FROM c2_rooms WHERE status IN ('lobby','active','suspended','ending') AND (lease_until IS NULL OR lease_until <= $1 OR owner_id=$2) ORDER BY updated_at LIMIT 128",
                  [DB.time(), Application.get_env(:ruxi, :core_instance, "local-core")]
                ) do
            Store.tick(DB.str(r["id"]))
          end

          Store.drain()
        end
      end)
    rescue
      _ in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] -> :ok
    catch
      {:error, _} -> :ok
    end

    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end
end
