defmodule Ruxi.AuthGuard do
  @moduledoc "Bounded, process-local authentication failure budgets; stores only digests."
  use GenServer
  alias Ruxi.Util
  @window 60_000
  @capacity 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(s), do: {:ok, s}

  def run(scope, ip, code, fun) do
    code = if is_binary(code), do: code, else: "invalid"
    keys = [{Util.hash(["peer", scope, ip]), 20}, {Util.hash(["code", scope, code]), 5}]
    request = make_ref()

    case GenServer.call(__MODULE__, {:reserve, keys, request}) do
      :ok -> :ok
      {:limited, wait} -> throw({:error, "RATE_LIMITED", wait})
    end

    try do
      result = fun.()
      failed = match?({:error, _}, result)
      GenServer.call(__MODULE__, {:finish, keys, request, failed})
      result
    catch
      kind, reason ->
        GenServer.call(__MODULE__, {:finish, keys, request, true})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def handle_call({:reserve, keys, request}, _, s) do
    now = System.monotonic_time(:millisecond)
    s = prune(s, now)

    wait =
      Enum.reduce(keys, 0, fn {key, limit}, wait ->
        entries = Map.get(s, key, %{})

        if map_size(entries) >= limit,
          do: max(wait, Enum.min(Map.values(entries)) + @window - now),
          else: wait
      end)

    new_keys = Enum.count(keys, fn {key, _} -> not Map.has_key?(s, key) end)

    cond do
      wait > 0 ->
        {:reply, {:limited, wait}, s}

      map_size(s) + new_keys > @capacity ->
        {:reply, {:limited, 1000}, s}

      true ->
        s =
          Enum.reduce(keys, s, fn {key, _}, acc ->
            Map.update(acc, key, %{request => now}, &Map.put(&1, request, now))
          end)

        {:reply, :ok, s}
    end
  end

  def handle_call({:finish, keys, request, failed}, _, s) do
    s =
      if failed,
        do: s,
        else:
          Enum.reduce(keys, s, fn {key, _}, acc ->
            Map.update(acc, key, %{}, &Map.delete(&1, request))
          end)

    {:reply, :ok, s}
  end

  defp prune(s, now),
    do:
      Map.new(
        Enum.flat_map(s, fn {key, entries} ->
          live = Map.new(Enum.filter(entries, fn {_, at} -> now - at < @window end))
          if map_size(live) == 0, do: [], else: [{key, live}]
        end)
      )
end
