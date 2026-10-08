defmodule Ruxi.Limiter do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(s), do: {:ok, s}

  def check!(key, rate, burst) do
    Ruxi.Util.require!(GenServer.call(__MODULE__, {key, rate, burst}), "RATE_LIMITED")
  end

  def handle_call({key, rate, burst}, _, s) do
    now = System.monotonic_time(:millisecond)

    s =
      if map_size(s) >= 10_000,
        do: Map.new(Enum.filter(s, fn {_, {_, at}} -> now - at < 60_000 end)),
        else: s

    if map_size(s) >= 10_000 and not Map.has_key?(s, key) do
      {:reply, false, s}
    else
      {tokens, last} = Map.get(s, key, {burst, now})
      available = min(burst, tokens + (now - last) * rate / 1000)
      ok = available >= 1
      s = Map.put(s, key, {if(ok, do: available - 1, else: available), now})

      s =
        if map_size(s) > 10_000,
          do: Map.new(Enum.filter(s, fn {_, {_, at}} -> now - at < 60_000 end)),
          else: s

      {:reply, ok, s}
    end
  end
end

defmodule Ruxi.StrictJSON do
  def decode!(raw, _opts \\ []) do
    raw |> Jason.decode!(objects: :ordered_objects) |> normalize()
  end

  defp normalize(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    if length(keys) != length(Enum.uniq(keys)), do: raise(ArgumentError, "duplicate JSON key")
    Map.new(values, fn {k, v} -> {k, normalize(v)} end)
  end

  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end

defmodule RuxiWeb.Serializer do
  @behaviour Phoenix.Socket.Serializer
  defdelegate fastlane!(msg), to: Phoenix.Socket.V2.JSONSerializer
  defdelegate encode!(msg), to: Phoenix.Socket.V2.JSONSerializer

  def decode!(raw, opts) do
    if opts[:opcode] != :text or byte_size(raw) > 16_384,
      do: raise(ArgumentError, "invalid frame")

    case Ruxi.StrictJSON.decode!(raw) do
      [join, ref, topic, event, payload] when is_map(payload) ->
        %Phoenix.Socket.Message{
          join_ref: join,
          ref: ref,
          topic: topic,
          event: event,
          payload: payload
        }

      _ ->
        raise ArgumentError, "invalid Phoenix frame"
    end
  end
end
