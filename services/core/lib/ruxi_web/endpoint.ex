defmodule RuxiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ruxi

  socket("/api/socket", RuxiWeb.Socket,
    websocket: [timeout: 60_000, compress: false, serializer: [{RuxiWeb.Serializer, "~> 2.0.0"}]],
    longpoll: false
  )

  plug(CORSPlug,
    origin: &RuxiWeb.Endpoint.allowed_origins/0,
    headers: [
      "authorization",
      "content-type",
      "x-device-id",
      "x-control-generation",
      "range",
      "idempotency-key",
      "if-match"
    ],
    expose: ["accept-ranges", "content-range", "content-length", "retry-after"]
  )

  plug(Plug.RequestId)
  plug(Ruxi.Uploads)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Ruxi.StrictJSON,
    length: 1_048_576
  )

  plug(RuxiWeb.Router)

  def allowed_origins,
    do:
      Application.get_env(:ruxi, :allowed_origins, [
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://localhost:8081"
      ])
end

defmodule RuxiWeb.Socket do
  use Phoenix.Socket
  channel("player_room:*", RuxiWeb.RoomChannel)
  channel("room:*", RuxiWeb.C2RoomChannel)

  def connect(%{"ticket" => ticket}, socket, _) do
    result =
      if String.starts_with?(ticket, "c2."),
        do: Ruxi.C2.Store.consume_ticket(ticket),
        else: Ruxi.Auth.consume_ticket(ticket)

    case result do
      {:ok, ctx} -> {:ok, assign(socket, :ctx, ctx)}
      _ -> :error
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> :error
  end

  def connect(_, _, _), do: :error
  def id(socket), do: "session:#{socket.assigns.ctx.session}"
end

defmodule RuxiWeb.RoomChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false
  alias Ruxi.{Auth, Store, Util, DB, RoomServer}
  intercept(["view_event"])

  def handle_out("view_event", event, socket) do
    try do
      Auth.valid!(socket.assigns.ctx)
      Store.auth!(Store.load!(socket.assigns.ctx.room)["state_json"], socket.assigns.ctx)
      {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

      Util.require!(
        queued <= 200 and byte_size(Jason.encode!(event)) <= 131_072,
        "RESYNC_REQUIRED"
      )

      floor =
        DB.one("SELECT replay_floor_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(socket.assigns.ctx.room),
          DB.uuid(socket.assigns.ctx.member)
        ])["replay_floor_seq"]

      if event["seq"] > floor and event["seq"] > socket.assigns.base_seq do
        push(socket, "view_event", event)
        {:noreply, assign(socket, :sent_through, max(socket.assigns.sent_through, event["seq"]))}
      else
        {:noreply, socket}
      end
    rescue
      _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:stop, :normal, socket}
    catch
      {:error, _} -> {:stop, :normal, socket}
    end
  end

  def join(topic, p, socket) do
    ctx = socket.assigns.ctx

    valid =
      is_map(p) and
        Enum.sort(Map.keys(p)) ==
          Enum.sort(~w(protocol_version control_generation recovery_epoch last_seq has_snapshot)) and
        is_integer(p["last_seq"]) and p["last_seq"] in 0..9_007_199_254_740_991 and
        is_binary(p["recovery_epoch"]) and byte_size(p["recovery_epoch"]) <= 128 and
        is_boolean(p["has_snapshot"])

    if valid and topic == "player_room:#{ctx.room}:#{ctx.member}" and p["protocol_version"] == 1 and
         p["control_generation"] == ctx.generation do
      Ruxi.Connections.join(ctx, self())

      with {:ok, _} <- RoomServer.presence(ctx, true),
           {:ok, baseline} <- Store.sync_baseline(ctx, p) do
        sync = Util.id()
        send(self(), {:sync, baseline, sync})

        {:ok,
         %{
           "protocol_version" => 1,
           "sync_id" => sync,
           "mode" => baseline["mode"],
           "base_seq" => baseline["base_seq"],
           "recovery_epoch" => Util.epoch(),
           "auth_expires_at" => Util.iso(ctx.expires)
         },
         assign(socket,
           synced: false,
           sync_id: sync,
           through: baseline["base_seq"],
           base_seq: baseline["base_seq"],
           sent_through: baseline["base_seq"]
         )}
      else
        {:error, code} ->
          {:error, %{"error" => Util.error(code)}}
      end
    else
      {:error, %{"error" => Util.error("NOT_ALLOWED")}}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, %{"error" => Util.error("OWNER_UNAVAILABLE")}}
  catch
    :exit, _ -> {:error, %{"error" => Util.error("OWNER_UNAVAILABLE")}}
  end

  def handle_info({:sync, baseline, sync}, socket) do
    case Store.events(socket.assigns.ctx, baseline["base_seq"], Util.epoch()) do
      {:ok, tail} ->
        if baseline["mode"] == "snapshot" do
          push(
            socket,
            "sync_snapshot",
            Map.merge(Map.delete(baseline, "mode"), %{"sync_id" => sync})
          )
        end

        for event <- tail["events"], do: push(socket, "view_event", event)
        through = tail["next_after_seq"]

        push(socket, "sync_complete", %{
          "sync_id" => sync,
          "through_seq" => through,
          "recovery_epoch" => Util.epoch()
        })

        Process.send_after(self(), :watermark, 5000)

        if tail["has_more"] do
          push(socket, "resync_required", %{
            "reason" => "RESYNC_REQUIRED",
            "recovery_epoch" => Util.epoch()
          })

          {:stop, :normal, socket}
        else
          {:noreply, assign(socket, through: through, sent_through: through)}
        end

      {:error, code} ->
        push(socket, "resync_required", %{"reason" => code, "recovery_epoch" => Util.epoch()})
        {:stop, :normal, socket}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:stop, :normal, socket}
  end

  def handle_info(:watermark, socket) do
    ctx = socket.assigns.ctx

    check =
      try do
        Auth.valid!(ctx)
        Store.auth!(Store.load!(ctx.room)["state_json"], ctx)
        :ok
      rescue
        _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, "OWNER_UNAVAILABLE"}
      catch
        {:error, c} -> {:error, c}
      end

    case check do
      :ok ->
        m =
          DB.one(
            "SELECT view_seq,replay_floor_seq FROM room_members WHERE room_id=$1 AND id=$2",
            [DB.uuid(ctx.room), DB.uuid(ctx.member)]
          )

        push(socket, "watermark", Map.put(m, "recovery_epoch", Util.epoch()))

        if ctx.expires - Util.now() < 30_000,
          do: push(socket, "auth_expiring", %{"expires_at" => Util.iso(ctx.expires)})

        Process.send_after(self(), :watermark, 5000)
        {:noreply, socket}

      {:error, code} ->
        push(socket, "resync_required", %{"reason" => code, "recovery_epoch" => Util.epoch()})
        {:stop, :normal, socket}
    end
  end

  def handle_in("sync_ack", %{"sync_id" => id, "last_seq" => seq} = p, socket) do
    try do
      Util.require!(
        map_size(p) == 2 and is_integer(seq) and seq in 0..9_007_199_254_740_991,
        "INVALID_ARGUMENT"
      )

      Auth.valid!(socket.assigns.ctx)
      Store.auth!(Store.load!(socket.assigns.ctx.room)["state_json"], socket.assigns.ctx)

      current =
        DB.one("SELECT view_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(socket.assigns.ctx.room),
          DB.uuid(socket.assigns.ctx.member)
        ])["view_seq"]

      Util.require!(
        id == socket.assigns.sync_id and seq >= socket.assigns.through and seq <= current,
        "RESYNC_REQUIRED"
      )

      {:reply, {:ok, %{}}, assign(socket, :synced, true)}
    rescue
      _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:stop, :normal, socket}
    catch
      {:error, code} -> {:reply, {:error, %{"error" => Util.error(code)}}, socket}
    end
  end

  def handle_in("command", c, socket) do
    r =
      try do
        Util.require!(is_map(c), "INVALID_ARGUMENT")
        Auth.valid!(socket.assigns.ctx)
        Ruxi.Limiter.check!({:command, socket.assigns.ctx.member}, 5, 10)

        if c["type"] == "chat_send",
          do: Ruxi.Limiter.check!({:chat, socket.assigns.ctx.member}, 0.6, 3)

        Util.require!(socket.assigns.synced, "NOT_ALLOWED")
        RoomServer.command(socket.assigns.ctx, c)
      rescue
        _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, "OWNER_UNAVAILABLE"}
        _ in [ArgumentError, Ecto.CastError] -> {:error, "INVALID_ARGUMENT"}
      catch
        :exit, _ -> {:error, "OWNER_UNAVAILABLE"}
        {:error, code} -> {:error, code}
      end

    case r do
      {:ok, reply} ->
        {:reply, {if(reply["status"] == "committed", do: :ok, else: :error), reply}, socket}

      {:error, code} ->
        {:reply, {:error, %{"error" => Util.error(code)}}, socket}
    end
  end

  def handle_in("clock_ping", %{"nonce" => nonce} = p, socket)
      when is_binary(nonce) and byte_size(nonce) <= 128 and map_size(p) == 1,
      do:
        {:reply,
         {:ok,
          %{
            "nonce" => p["nonce"],
            "server_received_at" => Util.iso(Util.now()),
            "server_sent_at" => Util.iso(Util.now())
          }}, socket}

  def handle_in(_, _, socket),
    do: {:reply, {:error, %{"error" => Util.error("INVALID_ARGUMENT")}}, socket}

  def terminate(_, socket) do
    if socket.assigns[:ctx] do
      online = Ruxi.Connections.leave(socket.assigns.ctx, self())
      if !online, do: RoomServer.presence(socket.assigns.ctx, false)
    end

    :ok
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error, MatchError] -> :ok
  catch
    :exit, _ -> :ok
  end
end
