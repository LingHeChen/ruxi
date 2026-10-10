defmodule Ruxi.DB do
  alias Ruxi.Repo

  def cloud?,
    do:
      Application.get_env(:ruxi, :database_backend, System.get_env("DB_BACKEND", "native")) ==
        "cloudbase"

  def query(sql, params \\ []) do
    if cloud?(), do: Ruxi.CloudDB.query(sql, params), else: native_query(sql, params)
  end

  def checked_query(sql, params \\ []) do
    if cloud?(), do: Ruxi.CloudDB.query(sql, params, true), else: native_query(sql, params)
  end

  defp native_query(sql, params),
    do:
      Ecto.Adapters.SQL.query!(
        Repo,
        sql,
        Enum.map(params, fn
          {:bytea, v} -> v
          {:json, v} -> v
          v -> v
        end),
        log: false
      )

  def bytes(value), do: {:bytea, value}
  def json(value), do: {:json, value}
  def checkout(fun), do: if(cloud?(), do: fun.(), else: Repo.checkout(fun))

  def broadcast(topic, event, data),
    do: after_commit(fn -> RuxiWeb.Endpoint.broadcast(topic, event, data) end)

  def after_commit(fun), do: if(cloud?(), do: Ruxi.CloudDB.after_commit(fun), else: fun.())

  def prefetch(queries), do: if(cloud?(), do: Ruxi.CloudDB.prefetch(queries), else: :ok)

  def rows(sql, params \\ []) do
    r = checked_query(sql, params)
    Enum.map(r.rows, &Map.new(Enum.zip(r.columns, &1)))
  end

  def one(sql, params \\ []), do: List.first(rows(sql, params))
  def uuid(s), do: if(cloud?(), do: Ecto.UUID.cast!(s), else: Ecto.UUID.dump!(s))
  def str(b) when is_binary(b) and byte_size(b) == 16, do: Ecto.UUID.load!(b)
  def str(s), do: s

  def time do
    if cloud?(),
      do: Ruxi.CloudDB.time(),
      else: one("SELECT floor(extract(epoch from clock_timestamp())*1000)::bigint AS ms")["ms"]
  end

  def transaction(fun) do
    if cloud?() do
      Ruxi.CloudDB.transaction(fun)
    else
      Repo.transaction(fn ->
        try do
          fun.()
        catch
          {:error, code} -> Repo.rollback(code)
        end
      end)
    end
  end
end
