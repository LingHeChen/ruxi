defmodule Ruxi.CloudDBBindingTest do
  use ExUnit.Case, async: true
  alias Ruxi.CloudDB

  test "binds placeholders without touching SQL literals, comments, or dollar strings" do
    sql = "SELECT $1, '$1', \"$1\", $$body $1$$, $2 -- $1\n/* $2 */"
    bound = CloudDB.bind(sql, ["a'\\; DROP TABLE users; --", 12])

    assert bound ==
             "SELECT E'a''\\\\; DROP TABLE users; --', '$1', \"$1\", $$body $1$$, 12 -- $1\n/* $2 */"
  end

  test "binary and JSON values have explicit database types" do
    assert CloudDB.bind("SELECT $1,$2", [{:bytea, <<0, 255>>}, {:json, []}]) ==
             "SELECT decode('00ff','hex'),E'[]'::jsonb"
  end
end

if System.get_env("HTTP_SQL_TEST_LOCAL") == "1" do
  defmodule Ruxi.CloudDBTransactionTest do
    use ExUnit.Case, async: false
    alias Ruxi.{DB, Util}

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
      id = Util.id()
      DB.query("INSERT INTO users(id,display_name) VALUES($1,'before')", [DB.uuid(id)])
      %{id: id}
    end

    test "writes are invisible until commit and reads see pending writes", %{id: id} do
      assert {:ok, "after"} =
               DB.transaction(fn ->
                 DB.query("UPDATE users SET display_name='after' WHERE id=$1", [DB.uuid(id)])

                 [["before"]] =
                   Ecto.Adapters.SQL.query!(
                     Ruxi.Repo,
                     "SELECT display_name FROM users WHERE id=$1",
                     [Ecto.UUID.dump!(id)]
                   ).rows

                 DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])[
                   "display_name"
                 ]
               end)

      assert DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])["display_name"] ==
               "after"
    end

    test "prefetch shares one read snapshot and invalidates changed rows", %{id: id} do
      assert {:ok, "after"} =
               DB.transaction(fn ->
                 query = {"SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)]}
                 DB.prefetch([query])
                 assert DB.one(elem(query, 0), elem(query, 1))["display_name"] == "before"
                 DB.query("UPDATE users SET display_name='after' WHERE id=$1", [DB.uuid(id)])
                 DB.one(elem(query, 0), elem(query, 1))["display_name"]
               end)
    end

    test "domain rejection discards writes and post-commit effects", %{id: id} do
      parent = self()

      assert {:error, "REJECTED"} =
               DB.transaction(fn ->
                 DB.query("UPDATE users SET display_name='after' WHERE id=$1", [DB.uuid(id)])
                 DB.after_commit(fn -> send(parent, :bad_effect) end)
                 Util.fail("REJECTED")
               end)

      refute_received :bad_effect

      assert DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])["display_name"] ==
               "before"
    end

    test "savepoint rollback preserves preceding writes", %{id: id} do
      assert {:ok, "first"} =
               DB.transaction(fn ->
                 DB.query("UPDATE users SET display_name='first' WHERE id=$1", [DB.uuid(id)])
                 DB.query("SAVEPOINT account_effect")
                 DB.query("UPDATE users SET display_name='second' WHERE id=$1", [DB.uuid(id)])

                 assert DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])[
                          "display_name"
                        ] == "second"

                 DB.query("ROLLBACK TO SAVEPOINT account_effect")
                 DB.query("RELEASE SAVEPOINT account_effect")

                 DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])[
                   "display_name"
                 ]
               end)
    end

    test "a changed observed row restarts computation and emits once", %{id: id} do
      original = Application.fetch_env!(:ruxi, :cloud_sql_transport)
      on_exit(fn -> Application.put_env(:ruxi, :cloud_sql_transport, original) end)
      Process.put(:inject_conflict, true)

      Application.put_env(:ruxi, :cloud_sql_transport, fn payload ->
        data = Jason.decode!(payload)

        if String.contains?(data["sql"], "$2::uuid") and Process.get(:inject_conflict) do
          Process.put(:inject_conflict, false)

          Ecto.Adapters.SQL.query!(
            Ruxi.Repo,
            "UPDATE users SET display_name='concurrent' WHERE id=$1",
            [Ecto.UUID.dump!(id)]
          )
        end

        original.(payload)
      end)

      parent = self()

      assert {:ok, "concurrent"} =
               DB.transaction(fn ->
                 name =
                   DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])[
                     "display_name"
                   ]

                 DB.after_commit(fn -> send(parent, :committed_once) end)
                 name
               end)

      assert_received :committed_once
      refute_received :committed_once
    end

    test "SQL errors roll back all earlier planned writes", %{id: id} do
      assert_raise Ruxi.CloudSQL.Error, fn ->
        DB.transaction(fn ->
          DB.query("UPDATE users SET display_name='after' WHERE id=$1", [DB.uuid(id)])
          DB.checked_query("SELECT 1/0")
        end)
      end

      assert DB.one("SELECT display_name FROM users WHERE id=$1", [DB.uuid(id)])["display_name"] ==
               "before"
    end
  end
end
