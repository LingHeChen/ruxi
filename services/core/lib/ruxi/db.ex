defmodule Ruxi.DB do
  alias Ruxi.Repo
  def query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  def rows(sql, params \\ []) do
    r = query(sql, params)
    Enum.map(r.rows, &Map.new(Enum.zip(r.columns, &1)))
  end

  def one(sql, params \\ []), do: List.first(rows(sql, params))
  def uuid(s), do: Ecto.UUID.dump!(s)
  def str(b) when is_binary(b) and byte_size(b) == 16, do: Ecto.UUID.load!(b)
  def str(s), do: s

  def time,
    do: one("SELECT floor(extract(epoch from clock_timestamp())*1000)::bigint AS ms")["ms"]

  def transaction(fun),
    do:
      Ruxi.Repo.transaction(fn ->
        try do
          fun.()
        catch
          {:error, code} -> Ruxi.Repo.rollback(code)
        end
      end)
end
