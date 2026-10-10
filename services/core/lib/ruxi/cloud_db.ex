defmodule Ruxi.CloudDB do
  @moduledoc """
  Optimistic SQL unit of work for CloudBase's sessionless HTTP gateway.

  Writes are deferred. Observed queries execute against a rollback-only plan,
  providing read-your-writes. A single commit validates all observations under
  the database writer lock. Conflicts restart computation; broadcasts run only
  after commit. This is not a cross-request PostgreSQL transaction.
  """
  alias Ruxi.CloudSQL
  @context {__MODULE__, :unit}
  @memo {__MODULE__, :memo}
  @bytes ~w(invite_cipher response_ciphertext reply_ciphertext)

  def verify! do
    row =
      Ruxi.DB.one(
        "SELECT to_regprocedure('ruxi.http_plan(jsonb,uuid,bigint)') IS NOT NULL AS ready, (SELECT max(version) FROM ruxi.schema_migrations)::bigint AS version, floor(extract(epoch FROM clock_timestamp())*1000)::bigint AS now"
      )

    unless row["ready"] and row["version"] >= 20_261_010_002_200 and
             abs(row["now"] - System.system_time(:millisecond)) < 5000,
           do: raise("CloudBase schema or clock verification failed")

    :ok
  end

  def transaction(fun) do
    if Process.get(@context) do
      try do
        {:ok, fun.()}
      catch
        {:error, code} -> throw({:error, code})
      end
    else
      Process.put(@memo, %{})

      try do
        attempt(fun, 0)
      after
        Process.delete(@memo)
      end
    end
  end

  def once(key, fun) do
    case Process.get(@memo) do
      nil ->
        fun.()

      memo ->
        if Map.has_key?(memo, key) do
          memo[key]
        else
          result = fun.()
          Process.put(@memo, Map.put(memo, key, result))
          result
        end
    end
  end

  defp attempt(fun, tries) do
    Process.put(@context, %{
      plan: [],
      cache: %{},
      effects: [],
      savepoints: %{},
      now: System.system_time(:millisecond)
    })

    outcome =
      try do
        value = fun.()
        context = Process.get(@context)
        commit!(context.plan, Ecto.UUID.generate(), context.now)
        {:committed, value, Enum.reverse(context.effects)}
      rescue
        e in CloudSQL.Error ->
          if e.code in ["DATABASE_40001", "DATABASE_40P01"] and tries < 4,
            do: :retry,
            else: reraise(e, __STACKTRACE__)
      catch
        {:error, code} -> {:error, code}
      after
        Process.delete(@context)
      end

    case outcome do
      {:committed, value, effects} ->
        for effect <- effects, do: effect.()
        {:ok, value}

      :retry ->
        attempt(fun, tries + 1)

      error ->
        error
    end
  end

  def time do
    case Process.get(@context) do
      nil -> System.system_time(:millisecond)
      context -> context.now
    end
  end

  def after_commit(fun) do
    case Process.get(@context) do
      nil ->
        fun.()

      context ->
        Process.put(@context, %{context | effects: [fun | context.effects]})
        :ok
    end
  end

  def query(sql, params, observed \\ false) do
    mode =
      if Regex.match?(~r/\A\s*(SELECT|WITH)\b|\bRETURNING\b/i, sql), do: "rows", else: "command"

    sql = sql |> String.replace(~r/\bclock_timestamp\(\)/i, "ruxi.http_clock()") |> bind(params)

    case savepoint(sql) do
      :normal -> execute(sql, observed, mode)
      result -> result
    end
  end

  def prefetch(queries) do
    context = Process.get(@context) || raise "prefetch outside transaction"

    items =
      Enum.map(queries, fn {sql, params} ->
        sql =
          sql |> String.replace(~r/\bclock_timestamp\(\)/i, "ruxi.http_clock()") |> bind(params)

        sql = String.trim_trailing(String.trim(sql), ";")

        unless Regex.match?(~r/\ASELECT\b/i, sql),
          do: raise(ArgumentError, "prefetch requires SELECT")

        %{"sql" => sql, "mode" => "rows"}
      end)

    items = Enum.reject(items, &Map.has_key?(context.cache, &1["sql"]))

    if items != [] do
      replies = preview!(context.plan ++ items, context.now) |> Enum.take(-length(items))

      {plan, cache} =
        Enum.zip(items, replies)
        |> Enum.reduce({context.plan, context.cache}, fn {item, reply}, {plan, cache} ->
          {plan ++ [Map.put(item, "expect", reply)], Map.put(cache, item["sql"], reply)}
        end)

      Process.put(@context, %{context | plan: plan, cache: cache})
    end

    :ok
  end

  # Retain observations of unrelated tables, never cross-request data. Unknown
  # mutations conservatively invalidate everything; savepoint snapshots include
  # both the plan and this cache.
  defp invalidate(cache, sql) do
    case Regex.run(
           ~r/\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+((?:[a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*)\b/i,
           sql
         ) do
      [_, target] ->
        table = target |> String.split(".") |> List.last() |> String.downcase()

        # These hot-path tables only update themselves (including the room
        # retention trigger). Deletes/unknown tables may cascade: clear all.
        safe =
          ~w(c2_rooms c2_room_members c2_actor_states c2_knowledge c2_known_locations c2_intents c2_step_settlements c2_ownership c2_offers c2_endings c2_view_events c2_outbox c2_commands)

        if table not in safe or String.starts_with?(String.upcase(String.trim(sql)), "DELETE"),
          do: %{},
          else:
            Map.reject(cache, fn {query, _} ->
              Regex.scan(
                ~r/\b(?:FROM|JOIN)\s+((?:[a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*)\b/i,
                query
              )
              |> Enum.any?(fn [_, name] ->
                name |> String.split(".") |> List.last() |> String.downcase() == table
              end)
            end)

      _ ->
        %{}
    end
  end

  defp execute(sql, observed, mode) do
    sql = String.trim_trailing(String.trim(sql), ";")
    item = %{"sql" => sql, "mode" => mode}
    context = Process.get(@context)

    cond do
      context == nil ->
        # Plain reads use their statement snapshot without serializing behind
        # writes. Mutations and locking reads retain the common writer lock.
        read_only =
          Regex.match?(~r/\A\s*SELECT\b/i, sql) and
            not Regex.match?(~r/\bFOR\s+(UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b/i, sql)

        statements =
          if read_only,
            do: [item],
            else: [
              %{
                "sql" => "SELECT pg_advisory_xact_lock(787898120261010::bigint)",
                "mode" => "rows"
              },
              item
            ]

        reply = CloudSQL.batch!(statements) |> List.last()
        result(reply)

      not observed ->
        Process.put(@context, %{
          context
          | plan: context.plan ++ [Map.put(item, "mode", "command")],
            cache: invalidate(context.cache, sql)
        })

        %{columns: [], rows: [], num_rows: nil}

      Map.has_key?(context.cache, sql) ->
        result(context.cache[sql])

      true ->
        results = preview!(context.plan ++ [item], context.now)
        current = List.last(results)
        item = Map.put(item, "expect", current)

        cache =
          if mode == "rows" and Regex.match?(~r/\A\s*SELECT\b/i, sql),
            do: Map.put(context.cache, sql, current),
            else: invalidate(context.cache, sql)

        Process.put(@context, %{context | plan: context.plan ++ [item], cache: cache})
        result(current)
    end
  end

  defp preview!(plan, now) do
    [%{"value" => %{"results" => results}}] =
      CloudSQL.execute!(
        "SELECT ruxi.http_plan($1::jsonb,NULL,$2::bigint) AS value",
        [Jason.encode!(plan), now]
      )

    results
  end

  defp commit!(plan, id, now) do
    payload = [Jason.encode!(plan), id, now]

    try do
      CloudSQL.execute!("SELECT ruxi.http_plan($1::jsonb,$2::uuid,$3::bigint) AS value", payload)
    rescue
      e in CloudSQL.Error ->
        if e.code == "DATABASE_UNAVAILABLE" or e.status in 500..599 do
          # The exact same plan/id can be retried safely: the durable receipt
          # distinguishes an already committed request from an uncommitted one.
          CloudSQL.execute!(
            "SELECT ruxi.http_plan($1::jsonb,$2::uuid,$3::bigint) AS value",
            payload
          )
        else
          reraise(e, __STACKTRACE__)
        end
    end
  end

  defp result(%{"rows" => rows, "num_rows" => n}) do
    columns =
      case rows do
        [first | _] -> Map.keys(first) |> Enum.sort()
        _ -> []
      end

    values = Enum.map(rows, fn row -> Enum.map(columns, &decode(&1, row[&1])) end)
    %{columns: columns, rows: values, num_rows: n}
  end

  defp decode(key, "\\x" <> value) when key in @bytes, do: Base.decode16!(value, case: :mixed)
  defp decode(_, value), do: value

  defp savepoint(sql) do
    case Regex.run(
           ~r/\A\s*(SAVEPOINT|ROLLBACK TO SAVEPOINT|RELEASE SAVEPOINT)\s+([a-z_]+)\s*\z/i,
           sql
         ) do
      nil ->
        :normal

      [_, action, name] ->
        context = Process.get(@context) || raise "savepoint outside unit of work"

        next =
          case String.upcase(action) do
            "SAVEPOINT" ->
              %{context | savepoints: Map.put(context.savepoints, name, context)}

            "ROLLBACK TO SAVEPOINT" ->
              saved = Map.fetch!(context.savepoints, name)
              %{saved | savepoints: context.savepoints}

            "RELEASE SAVEPOINT" ->
              %{context | savepoints: Map.delete(context.savepoints, name)}
          end

        Process.put(@context, next)
        %{columns: [], rows: [], num_rows: 0}
    end
  end

  @doc "Bind only SQL placeholders; quoted SQL, comments and dollar strings stay intact."
  def bind(sql, params) do
    # Application SQL contains no escaped E strings; values are always encoded as
    # UTF-8 hex, so SQL quoting/backslash settings cannot change their meaning.
    token =
      ~r/\$([0-9]+)\b|'(?:''|[^'])*'|"(?:""|[^"])*"|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/|\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$[\s\S]*?\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/

    Regex.replace(token, sql, fn full, index ->
      if index == "", do: full, else: literal(Enum.fetch!(params, String.to_integer(index) - 1))
    end)
  end

  defp literal({:json, value}), do: literal(Jason.encode!(value)) <> "::jsonb"
  defp literal(nil), do: "NULL"
  defp literal(true), do: "TRUE"
  defp literal(false), do: "FALSE"
  defp literal(n) when is_integer(n), do: Integer.to_string(n)
  defp literal(n) when is_float(n), do: Float.to_string(n)

  defp literal({:bytea, bytes}),
    do: "decode('" <> Base.encode16(bytes, case: :lower) <> "','hex')"

  defp literal(%DateTime{} = dt), do: literal(DateTime.to_iso8601(dt)) <> "::timestamptz"
  defp literal(%NaiveDateTime{} = dt), do: literal(NaiveDateTime.to_iso8601(dt)) <> "::timestamp"
  defp literal(%Date{} = date), do: literal(Date.to_iso8601(date)) <> "::date"
  defp literal(map) when is_map(map), do: literal(Jason.encode!(map)) <> "::jsonb"

  defp literal(list) when is_list(list) do
    if Enum.any?(list, &(is_map(&1) or is_list(&1) or is_boolean(&1))) do
      literal(Jason.encode!(list)) <> "::jsonb"
    else
      array_literal(list)
    end
  end

  defp literal(value) when is_binary(value) do
    unless String.valid?(value), do: raise(ArgumentError, "binary parameter requires DB.bytes/1")
    # Untyped string literals retain PostgreSQL contextual type inference.
    "E'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"
  end

  defp array_literal(list) do
    value =
      "{" <>
        Enum.map_join(list, ",", fn
          nil ->
            "NULL"

          s when is_binary(s) ->
            "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

          n when is_number(n) ->
            to_string(n)
        end) <> "}"

    literal(value)
  end
end
