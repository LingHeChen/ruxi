defmodule RuxiWeb.C2RoomChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false
  alias Ruxi.C2.Store
  alias Ruxi.Util
  intercept(["room.view", "communication.changed"])

  def join(topic, p, socket) do
    ctx = socket.assigns.ctx

    try do
      Util.require!(
        Map.get(ctx, :c2) == true and topic == "room:#{ctx.room}:member:#{ctx.member}" and
          is_map(p) and p["protocol_version"] in [2, 3] and
          p["control_epoch"] == ctx.control_epoch,
        "NOT_ALLOWED"
      )

      Store.socket_valid!(ctx)
      {:ok, snapshot} = Store.snapshot(ctx, ctx.room)

      Util.require!(
        p["protocol_version"] == snapshot["protocol_version"],
        "UNSUPPORTED_CAPABILITY"
      )

      reference = Ruxi.Util.id()
      Ruxi.SceneVoice.Coordinator.socket_connected(ctx, reference)
      socket = assign(socket, :voice_socket_ref, reference)

      {:ok, %{"snapshot" => snapshot, "mode" => "snapshot"},
       assign(socket, :view_seq, snapshot["view_seq"])}
    catch
      {:error, code} -> {:error, %{"code" => code}}
    end
  end

  def handle_out("room.view", view, socket) do
    try do
      m = Store.socket_valid!(socket.assigns.ctx)
      {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

      Util.require!(
        queued <= 256 and byte_size(Jason.encode!(view)) <= 1_048_576,
        "RESYNC_REQUIRED"
      )

      if view["stream_id"] == Ruxi.DB.str(m["stream_id"]) and
           view["view_seq"] > socket.assigns.view_seq do
        push(socket, "room.view", view)
        {:noreply, assign(socket, :view_seq, view["view_seq"])}
      else
        {:noreply, socket}
      end
    catch
      {:error, _} -> {:stop, :normal, socket}
    end
  end

  def handle_out("communication.changed", _, socket) do
    try do
      Store.socket_valid!(socket.assigns.ctx)
      state = Ruxi.C2.Communication.voice(socket.assigns.ctx, socket.assigns.ctx.room)

      push(socket, "voice.state", %{
        "type" => "voice.state",
        "cause" => "participation",
        "world_revision" => state["world_revision"],
        "state" => state
      })

      push(socket, "chat.changed", %{})
      {:noreply, socket}
    catch
      {:error, _} -> {:stop, :normal, socket}
    end
  end

  def handle_in("room.command", p, socket),
    do: respond(Store.command(socket.assigns.ctx, socket.assigns.ctx.room, p), socket)

  def handle_in("view.ack", p, socket) when is_map(p),
    do: respond(Store.ack(socket.assigns.ctx, p), socket)

  def handle_in("clock.ping", p, socket) when is_map(p) do
    if Map.keys(p) == ["nonce"] and is_binary(p["nonce"]) and byte_size(p["nonce"]) <= 128 do
      case Store.heartbeat(socket.assigns.ctx) do
        {:ok, value} -> respond({:ok, Map.put(value, "nonce", p["nonce"])}, socket)
        result -> respond(result, socket)
      end
    else
      respond({:error, "INVALID_ARGUMENT"}, socket)
    end
  end

  def handle_in(_, _, socket), do: respond({:error, "INVALID_ARGUMENT"}, socket)

  def terminate(_, socket) do
    if socket.assigns[:voice_socket_ref] do
      try do
        Ruxi.SceneVoice.Coordinator.socket_disconnected(
          socket.assigns.ctx,
          socket.assigns.voice_socket_ref
        )
      rescue
        _ in [DBConnection.ConnectionError, DBConnection.OwnershipError] -> :ok
      catch
        {:error, _} -> :ok
      end
    end

    :ok
  end

  defp respond({:ok, value}, socket), do: {:reply, {:ok, value}, socket}
  defp respond({:error, code}, socket), do: {:reply, {:error, %{"code" => code}}, socket}
end
