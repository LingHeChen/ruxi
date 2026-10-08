defmodule Ruxi.Connections do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(s), do: {:ok, s}
  def join(ctx, pid), do: GenServer.call(__MODULE__, {:join, ctx, pid})
  def leave(ctx, pid), do: GenServer.call(__MODULE__, {:leave, ctx, pid})

  def online?(room, member, generation),
    do: GenServer.call(__MODULE__, {:online, room, member, generation})

  defp key(ctx), do: {ctx.room, ctx.member, ctx.generation}

  def handle_call({:join, ctx, pid}, _, s) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(s, ref, {ctx, pid})}
  end

  def handle_call({:leave, ctx, pid}, _, s) do
    {remove, keep} = Enum.split_with(s, fn {_, {c, p}} -> key(c) == key(ctx) and p == pid end)
    for {ref, _} <- remove, do: Process.demonitor(ref, [:flush])
    s = Map.new(keep)
    {:reply, Enum.any?(keep, fn {_, {c, _}} -> key(c) == key(ctx) end), s}
  end

  def handle_call({:online, r, m, g}, _, s),
    do: {:reply, Enum.any?(s, fn {_, {c, _}} -> key(c) == {r, m, g} end), s}

  def handle_info({:DOWN, ref, :process, _pid, _}, s) do
    case Map.pop(s, ref) do
      {nil, s} ->
        {:noreply, s}

      {{ctx, _}, s} ->
        if !Enum.any?(s, fn {_, {c, _}} -> key(c) == key(ctx) end),
          do: Task.start(fn -> Ruxi.RoomServer.presence(ctx, false) end)

        {:noreply, s}
    end
  end
end
