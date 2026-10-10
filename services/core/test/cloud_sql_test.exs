defmodule Ruxi.CloudSQLTest do
  use ExUnit.Case, async: false
  alias Ruxi.CloudSQL

  setup do
    previous = Application.get_env(:ruxi, :cloud_sql_transport)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ruxi, :cloud_sql_transport, previous),
        else: Application.delete_env(:ruxi, :cloud_sql_transport)
    end)
  end

  test "parameterization preserves quotes and JSON results" do
    Application.put_env(:ruxi, :cloud_sql_transport, fn payload ->
      assert %{"parameters" => ["a'quoted", 7, true, nil], "role" => "cloudbase_postgres"} =
               Jason.decode!(payload)

      {200, ~s([{"data":{"x":1}}])}
    end)

    assert [%{"data" => %{"x" => 1}}] = CloudSQL.execute!("SELECT $1", ["a'quoted", 7, true, nil])
  end

  test "atomic batch uses one parameterized request" do
    statements = [%{"sql" => "SELECT 1 AS n", "mode" => "rows"}]

    Application.put_env(:ruxi, :cloud_sql_transport, fn payload ->
      assert %{"sql" => "SELECT ruxi.http_batch($1::jsonb) AS result", "parameters" => [json]} =
               Jason.decode!(payload)

      assert Jason.decode!(json) == statements
      {200, ~s([{"result":[{"rows":[{"n":1}],"num_rows":1}]}])}
    end)

    assert [%{"num_rows" => 1}] = CloudSQL.batch!(statements)
  end

  test "errors do not leak gateway response text" do
    Application.put_env(:ruxi, :cloud_sql_transport, fn _ ->
      {400, ~s({"code":"DATABASE_23505","message":"secret-value"})}
    end)

    error =
      assert_raise CloudSQL.Error, fn -> CloudSQL.execute!("SELECT $1", ["secret-value"]) end

    assert error.code == "DATABASE_23505"
    refute Exception.message(error) =~ "secret-value"
  end

  test "rejects binary UUID and structured parameters" do
    assert_raise ArgumentError, fn -> CloudSQL.execute!("SELECT $1", [<<255, 0>>]) end
    assert_raise ArgumentError, fn -> CloudSQL.execute!("SELECT $1", [%{}]) end
  end
end
