defmodule Ruxi.Application do
  use Application

  def start(_, _) do
    if Ruxi.DB.cloud?() do
      # HTTP SQL, storage, maintenance, and player sockets share this profile.
      # The default two connections otherwise queue unrelated player requests.
      :ok = :httpc.set_options(max_sessions: 32, max_keep_alive_length: 1000)
      Ruxi.CloudDB.verify!()
    end

    Supervisor.start_link(
      database_children() ++
        [
          Ruxi.Privacy,
          Ruxi.Limiter,
          Ruxi.AuthGuard,
          Ruxi.Connections,
          {Phoenix.PubSub, name: Ruxi.PubSub},
          {Registry, keys: :unique, name: Ruxi.RoomRegistry},
          {DynamicSupervisor, name: Ruxi.RoomSupervisor, strategy: :one_for_one},
          Ruxi.Dispatcher,
          Ruxi.C2.Maintenance,
          {Task.Supervisor, name: Ruxi.VoiceTasks},
          Ruxi.SceneVoice.Maintenance,
          maintenance_child(),
          RuxiWeb.Endpoint
        ],
      strategy: :one_for_one,
      name: Ruxi.Supervisor
    )
  end

  defp database_children, do: if(Ruxi.DB.cloud?(), do: [], else: [Ruxi.Repo])

  defp maintenance_child do
    if Ruxi.DB.cloud?(),
      do: Ruxi.CloudMaintenance,
      else: {Oban, Application.fetch_env!(:ruxi, Oban)}
  end
end

defmodule Ruxi.Repo do
  use Ecto.Repo, otp_app: :ruxi, adapter: Ecto.Adapters.Postgres
end

defmodule Ruxi.Util do
  def id, do: Ecto.UUID.generate()
  def now, do: System.system_time(:millisecond)
  def iso(nil), do: nil
  def iso(ms), do: DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()
  def epoch, do: Application.fetch_env!(:ruxi, :recovery_epoch)
  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  def hash(s) when is_binary(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  def hash(s), do: hash(canonical(s))

  def canonical(m) when is_map(m),
    do:
      "{" <>
        (m
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"

  def canonical(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &canonical/1) <> "]"
  def canonical(v), do: Jason.encode!(v)

  def error(code, retryable \\ false),
    do: %{"code" => code, "message" => code, "retryable" => retryable, "trace_id" => id()}

  def fail(code), do: throw({:error, code})
  def require!(true, _), do: :ok
  def require!(_, code), do: fail(code)
end
