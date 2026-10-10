ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Ruxi.Repo, :manual)

# Exercise the HTTP persistence contract against an isolated local PostgreSQL
# database without sending test fixtures to the production CloudBase environment.
if System.get_env("HTTP_SQL_TEST_LOCAL") == "1" do
  Application.put_env(:ruxi, :database_backend, "cloudbase")

  Application.put_env(:ruxi, :cloud_sql_transport, fn payload ->
    data = Jason.decode!(payload)

    params =
      data["parameters"]
      |> Enum.with_index()
      |> Enum.map(fn
        {json, 0} -> Jason.decode!(json)
        {id, 1} when is_binary(id) -> Ecto.UUID.dump!(id)
        {value, _} -> value
      end)

    try do
      reply = Ecto.Adapters.SQL.query!(Ruxi.Repo, data["sql"], params, log: false)
      rows = Enum.map(reply.rows, &Map.new(Enum.zip(reply.columns, &1)))
      {200, Jason.encode!(rows)}
    rescue
      e in Postgrex.Error ->
        {400, Jason.encode!(%{"code" => "DATABASE_" <> e.postgres.pg_code})}
    end
  end)
end
