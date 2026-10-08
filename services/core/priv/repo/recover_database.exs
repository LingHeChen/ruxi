# Offline control entrypoint: mix run --no-start priv/repo/recover_database.exs
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
Logger.configure(level: :warning)
{:ok, _} = Ruxi.Repo.start_link()
{:ok, result} = Ruxi.Recovery.reset!()
Ruxi.Privacy.replay()
IO.puts(Jason.encode!(result))
