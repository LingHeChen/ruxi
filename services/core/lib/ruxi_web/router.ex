defmodule RuxiWeb.Router do
  use Plug.Router
  alias Ruxi.{DB, Util, Auth, Store}
  plug(:match)
  plug(:dispatch)

  get "/api/health" do
    send_json(conn, 200, %{"status" => "ok", "baseline" => "C1"})
  end

  get "/api/asset-preview/:capability" do
    try do
      Ruxi.Assets.poster(conn, capability)
    catch
      {:error, code} -> error(conn, code)
    end
  end

  get "/api/media/:capability" do
    try do
      Ruxi.Media.stream(conn, capability)
    catch
      {:error, "RATE_LIMITED", wait} -> error(conn, "RATE_LIMITED", wait)
      {:error, code} -> error(conn, code)
    end
  end

  get "/api/internal/work/:id/source" do
    try do
      attempt = List.first(get_req_header(conn, "x-work-attempt")) || ""

      p = %{
        "attempt" => String.to_integer(attempt),
        "lease_token" => List.first(get_req_header(conn, "x-lease-token"))
      }

      Ruxi.ProductionJobs.source(conn, id, p, worker(conn))
    rescue
      _ in ArgumentError -> error(conn, "INVALID_ARGUMENT")
    catch
      {:error, code} -> error(conn, code)
    end
  end

  match "/api/v2/*path" do
    RuxiWeb.C2API.call(conn)
  end

  match _ do
    try do
      data = dispatch(conn)

      {status, data} =
        case data do
          {:ok, %{"job_id" => nil}} -> {204, nil}
          {:ok, v} -> {200, v}
          {:error, code} -> Util.fail(code)
          {:created, v} -> {201, v}
          v -> {200, v}
        end

      if is_map(data) and data["auth_error"], do: Util.fail(data["auth_error"])
      trace = Util.id()

      conn =
        put_resp_header(conn, "x-request-id", trace)
        |> put_resp_header("cache-control", "no-store")

      if status == 204 do
        send_resp(conn, 204, "")
      else
        send_json(conn, status, %{
          "data" => data,
          "meta" => %{"trace_id" => trace, "server_time" => Util.iso(Util.now())}
        })
      end
    rescue
      _e in [ArgumentError, Ecto.CastError] -> error(conn, "INVALID_ARGUMENT")
      _ -> error(conn, "SERVICE_UNAVAILABLE")
    catch
      {:error, "RATE_LIMITED", wait} -> error(conn, "RATE_LIMITED", wait)
      {:error, code} -> error(conn, code)
    end
  end

  def json!(p, required, optional \\ []) do
    Util.require!(
      is_map(p) and Enum.all?(required, &Map.has_key?(p, &1)) and
        Enum.all?(Map.keys(p), &(&1 in (required ++ optional))),
      "INVALID_ARGUMENT"
    )

    for k <- required ++ optional,
        Map.has_key?(p, k),
        k in ~w(device_id command_id recovery_request_id login_request_id refresh_request_id story_id room_id asset_id),
        do: Util.require!(Ruxi.Contract.uuid?(p[k]), "INVALID_ARGUMENT")

    p
  end

  defp ctx(conn, audience \\ "player") do
    token =
      get_req_header(conn, "authorization")
      |> List.first()
      |> then(fn v ->
        if is_binary(v) and String.starts_with?(v, "Bearer "),
          do: String.replace_prefix(v, "Bearer ", ""),
          else: ""
      end)

    Auth.authenticate(token, audience)
  end

  defp private(conn, rid) do
    c = ctx(conn)
    d = get_req_header(conn, "x-device-id") |> List.first()
    g = get_req_header(conn, "x-control-generation") |> List.first()
    Util.require!(Ruxi.Contract.uuid?(d) and is_binary(g), "INVALID_ARGUMENT")
    Auth.member_context(c, rid, d, String.to_integer(g))
  end

  defp dispatch(conn) do
    p = conn.body_params
    method = conn.method
    path = conn.path_info

    case {method, path} do
      {"POST", ["api", "v1", "auth", "guest"]} ->
        Auth.guest(json!(p, ~w(device_id command_id)))

      {"POST", ["api", "v1", "auth", "recover"]} ->
        Ruxi.AuthGuard.run(
          "recover",
          :inet.ntoa(conn.remote_ip) |> to_string(),
          p["recovery_code"],
          fn ->
            Auth.recover(json!(p, ~w(recovery_code device_id recovery_request_id)))
          end
        )

      {"POST", ["api", "v1", "auth", "refresh"]} ->
        Auth.refresh(json!(p, ~w(refresh_token device_id refresh_request_id)), "player")

      {"POST", ["api", "v1", "auth", "logout"]} ->
        json!(p, [])
        Auth.logout(ctx(conn))

      {"POST", ["api", "v1", "auth", "register"]} ->
        Ruxi.AuthGuard.run(
          "account.register",
          to_string(:inet.ntoa(conn.remote_ip)),
          p["username"],
          fn ->
            c = if get_req_header(conn, "authorization") != [], do: ctx(conn), else: nil
            Ruxi.Accounts.register(p, c)
          end
        )

      {"POST", ["api", "v1", "auth", "password-reset"]} ->
        Ruxi.AuthGuard.run(
          "password.reset",
          to_string(:inet.ntoa(conn.remote_ip)),
          p["recovery_code"],
          fn -> Ruxi.Accounts.reset_password(p) end
        )

      {"POST", ["api", "v1", "auth", "login"]} ->
        Ruxi.AuthGuard.run(
          "account.login",
          to_string(:inet.ntoa(conn.remote_ip)),
          p["username"],
          fn -> Ruxi.Accounts.login(p) end
        )

      {"POST", ["api", "v1", "admin", "auth", "login"]} ->
        Ruxi.AuthGuard.run(
          "admin.login",
          to_string(:inet.ntoa(conn.remote_ip)),
          p["username"],
          fn -> Ruxi.Accounts.login(p, "admin") end
        )

      {"GET", ["api", "v1", "me"]} ->
        Ruxi.Accounts.profile(ctx(conn))

      {"PUT", ["api", "v1", "me"]} ->
        Ruxi.Accounts.update(ctx(conn), p)

      {"POST", ["api", "v1", "me", "password"]} ->
        Ruxi.AuthGuard.run("password.change", to_string(:inet.ntoa(conn.remote_ip)), nil, fn ->
          Ruxi.Accounts.change_password(ctx(conn), p)
        end)

      {"GET", ["api", "v1", "me", "favorites"]} ->
        Ruxi.Catalog.favorites(ctx(conn))

      {"POST", ["api", "v1", "stories", id, "favorite"]} ->
        Ruxi.Catalog.favorite(ctx(conn), id, p)

      {"PUT", ["api", "v1", "admin", "stories", id, "metadata"]} ->
        Ruxi.Catalog.metadata(ctx(conn, "admin"), id, p)

      {"POST", ["api", "v1", "me", "erase"]} ->
        Ruxi.Privacy.erase(ctx(conn), p)

      {"POST", ["api", "v1", "analytics", "batches"]} ->
        Ruxi.Telemetry.receive_batch(ctx(conn), p)

      {"POST", ["api", "v1", "rooms", rid, "chat", "reports"]} ->
        Ruxi.Chat.report(private(conn, rid), p)

      {"GET", ["api", "v1", "admin", "chat", "reports"]} ->
        Ruxi.Chat.queue(ctx(conn, "admin"))

      {"POST", ["api", "v1", "admin", "chat", "reports", id]} ->
        Ruxi.Chat.review(ctx(conn, "admin"), id, p)

      {"GET", ["api", "v1", "stories"]} ->
        Ruxi.Catalog.list(fetch_query_params(conn).query_params)

      {"GET", ["api", "v1", "stories", id]} ->
        Ruxi.Catalog.detail(id)

      {"POST", ["api", "v1", "rooms"]} ->
        Auth.create_room(ctx(conn), json!(p, ~w(story_id command_id))) |> created()

      {"POST", ["api", "v1", "rooms", "join"]} ->
        c = ctx(conn)

        Ruxi.AuthGuard.run("invite", :inet.ntoa(conn.remote_ip) |> to_string(), c.user, fn ->
          Auth.join_room(c, json!(p, ~w(invite_code command_id)))
        end)

      {"GET", ["api", "v1", "rooms"]} ->
        Ruxi.Catalog.rooms(ctx(conn))

      {"POST", ["api", "v1", "rooms", rid, "socket-ticket"]} ->
        Auth.ticket(ctx(conn), rid, json!(p, ~w(device_id takeover), ~w(command_id)))

      {"POST", ["api", "v1", "rooms", rid, "invites"]} ->
        c = private(conn, rid)
        json!(p, ~w(command_id))

        Auth.account(c, "invite.rotate", Map.put(p, "room_id", rid), fn ->
          s = Store.load!(rid, true)["state_json"]
          Store.auth!(s, c)
          Util.require!(s["lifecycle"] == "lobby" and s["host"] == c.member, "NOT_ALLOWED")
          now = DB.time()

          n =
            Map.merge(s, %{"invite" => Auth.invite_code(), "invite_expires" => now + 86_400_000})

          Store.save(s, n, "collaboration_changed", now)
          %{"invite_code" => n["invite"], "invite_expires_at" => Util.iso(n["invite_expires"])}
        end)

      {"GET", ["api", "v1", "rooms", rid, "snapshot"]} ->
        Store.snapshot(private(conn, rid))

      {"GET", ["api", "v1", "rooms", rid, "events"]} ->
        q = fetch_query_params(conn).query_params

        Store.events(
          private(conn, rid),
          String.to_integer(q["after_seq"] || "0"),
          q["recovery_epoch"],
          if(q["through_seq"], do: String.to_integer(q["through_seq"]), else: nil),
          String.to_integer(q["limit"] || "200")
        )

      {"GET", ["api", "v1", "rooms", rid, "watermark"]} ->
        c = private(conn, rid)
        s = Store.load!(rid)["state_json"]
        Store.auth!(s, c)
        q = fetch_query_params(conn).query_params
        Util.require!(q["recovery_epoch"] == Util.epoch(), "RECOVERY_CHANGED")

        DB.one("SELECT view_seq,replay_floor_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(rid),
          DB.uuid(c.member)
        ])
        |> Map.put("recovery_epoch", Util.epoch())

      {"GET", ["api", "v1", "rooms", rid, "commands", cid]} ->
        Store.receipt(private(conn, rid), cid)

      {"POST", ["api", "v1", "media", "access"]} ->
        json!(p, ~w(room_id asset_id device_id control_generation))
        origin = System.get_env("PUBLIC_API_URL", "#{conn.scheme}://#{conn.host}:#{conn.port}")
        Ruxi.Media.access(ctx(conn), p, origin)

      {"POST", ["api", "v1", "admin", "auth", "exchange"]} ->
        Ruxi.AuthGuard.run(
          "admin.exchange",
          :inet.ntoa(conn.remote_ip) |> to_string(),
          p["login_code"],
          fn ->
            Auth.admin_exchange(json!(p, ~w(login_code device_id login_request_id)))
          end
        )

      {"POST", ["api", "v1", "admin", "auth", "refresh"]} ->
        Auth.refresh(json!(p, ~w(refresh_token device_id refresh_request_id)), "admin")

      {"POST", ["api", "v1", "admin", "auth", "logout"]} ->
        Auth.logout(ctx(conn, "admin"))

      {"GET", ["api", "v1", "admin", "me"]} ->
        c = ctx(conn, "admin")
        Map.put(Ruxi.Accounts.profile(c), "roles", Auth.roles(c.user))

      {"GET", ["api", "v1", "admin", "users"]} ->
        Ruxi.Accounts.directory(ctx(conn, "admin"))

      {"POST", ["api", "v1", "admin", "users", id, "roles"]} ->
        Ruxi.Accounts.assign_roles(ctx(conn, "admin"), id, p)

      {"GET", ["api", "v1", "admin", "operations"]} ->
        Ruxi.Operations.report(ctx(conn, "admin"))

      {"GET", ["api", "v1", "admin", "assets"]} ->
        Ruxi.Assets.list(ctx(conn, "admin"))

      {"POST", ["api", "v1", "admin", "assets", "upload-intents"]} ->
        Ruxi.Assets.intent(ctx(conn, "admin"), p, origin(conn))

      {"POST", ["api", "v1", "admin", "assets", id, "captions"]} ->
        Ruxi.Assets.captions(ctx(conn, "admin"), id, p)

      {"GET", ["api", "v1", "admin", "assets", id, "preview"]} ->
        Ruxi.Assets.preview(ctx(conn, "admin"), id, origin(conn))

      {"POST", ["api", "v1", "admin", "assets", id, "complete"]} ->
        Ruxi.Assets.complete(ctx(conn, "admin"), id, p)

      {"POST", ["api", "v1", "admin", "versions", id, "ai"]} ->
        Ruxi.EditorAI.create(ctx(conn, "admin"), id, p)

      {"GET", ["api", "v1", "admin", "ai", "jobs", id]} ->
        Ruxi.EditorAI.get(ctx(conn, "admin"), id)

      {"POST", ["api", "v1", "admin", "ai", "jobs", id, "apply"]} ->
        Ruxi.EditorAI.apply(ctx(conn, "admin"), id, p)

      {"POST", ["api", "internal", "work", id, "output-intents"]} ->
        Ruxi.ProductionJobs.output_intents(id, p, worker(conn), origin(conn))

      {_, ["api", "v1", "admin" | rest]} ->
        Ruxi.Admin.dispatch(method, rest, p, ctx(conn, "admin"))

      {"POST", ["api", "internal", "work" | rest]} ->
        Util.require!(
          get_req_header(conn, "x-work-protocol") == ["1"],
          "UNAUTHORIZED"
        )

        token =
          case get_req_header(conn, "authorization") do
            ["Bearer " <> token] -> token
            _ -> nil
          end

        Ruxi.Jobs.dispatch(rest, p, Ruxi.WorkerAuth.authenticate(token))

      _ ->
        Util.fail("RESOURCE_NOT_FOUND")
    end
  end

  defp origin(conn),
    do: System.get_env("PUBLIC_API_URL", "#{conn.scheme}://#{conn.host}:#{conn.port}")

  defp worker(conn) do
    Util.require!(get_req_header(conn, "x-work-protocol") == ["1"], "UNAUTHORIZED")

    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    Ruxi.WorkerAuth.authenticate(token)
  end

  defp created({:ok, v}), do: {:created, v}
  defp created(v), do: v

  defp error(conn, code, wait \\ nil) do
    status =
      cond do
        code in ~w(UNAUTHORIZED AUTH_EXPIRED) -> 401
        code in ~w(RESOURCE_NOT_FOUND COMMAND_NOT_FOUND) -> 404
        code in ~w(NOT_ALLOWED NOT_MEMBER CONTROL_REPLACED) -> 403
        code == "SERVICE_UNAVAILABLE" -> 503
        code == "INVALID_ARGUMENT" -> 400
        code == "RATE_LIMITED" -> 429
        true -> 409
      end

    e = Util.error(code, status == 503)
    e = if is_integer(wait), do: Map.put(e, "retry_after_ms", wait), else: e

    conn =
      if is_integer(wait),
        do: put_resp_header(conn, "retry-after", to_string(ceil(wait / 1000))),
        else: conn

    conn
    |> put_resp_header("x-request-id", e["trace_id"])
    |> put_resp_header("cache-control", "no-store")
    |> send_json(status, %{"error" => e})
  end

  defp send_json(conn, status, value),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
end
