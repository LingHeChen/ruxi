defmodule Ruxi.CloudMaintenance do
  @moduledoc "Bounded periodic maintenance without a native Oban connection. Domain leases remain durable."
  use GenServer
  alias Ruxi.DB
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :tick, 60_000)
    {:ok, nil}
  end

  def handle_info(:tick, nil) do
    task =
      Task.Supervisor.async_nolink(Ruxi.VoiceTasks, fn ->
        Ruxi.Maintenance.perform(nil)

        DB.query(
          "DELETE FROM ruxi.http_commits WHERE created_at<clock_timestamp()-interval '7 days'"
        )
      end)

    {:noreply, task.ref}
  end

  def handle_info({ref, _}, ref) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :tick, 60_000)
    {:noreply, nil}
  end

  def handle_info({:DOWN, ref, _, _, _}, ref) do
    Process.send_after(self(), :tick, 60_000)
    {:noreply, nil}
  end
end
