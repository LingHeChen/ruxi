defmodule RuxiWeb.Router do
  use Plug.Router
  alias Ruxi.{DB, Util, Auth, Store}
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{"status" => "ok", "baseline" => "C1"})
  end

  get "/media/:capability" do
    try do
      Ruxi.Media.stream(conn, capability)
    catch
      {:error, code} -> error(conn, code)
    end
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
      {"POST", ["v1", "auth", "guest"]} ->
        Auth.guest(json!(p, ~w(device_id command_id)))

      {"POST", ["v1", "auth", "recover"]} ->
        Auth.recover(json!(p, ~w(recovery_code device_id recovery_request_id)))

      {"POST", ["v1", "auth", "refresh"]} ->
        Auth.refresh(json!(p, ~w(refresh_token device_id refresh_request_id)), "player")

      {"POST", ["v1", "auth", "logout"]} ->
        json!(p, [])
        Auth.logout(ctx(conn))

      {"GET", ["v1", "me"]} ->
        c = ctx(conn)
        %{"user_id" => c.user, "display_name" => "游客", "is_guest" => true}

      {"POST", ["v1", "me", "erase"]} ->
        Ruxi.Privacy.erase(ctx(conn), p)

      {"GET", ["v1", "stories"]} ->
        %{
          "items" =>
            DB.rows(
              "SELECT s.id,s.title,s.summary,s.seat_count FROM stories s JOIN content_versions v ON v.id=s.current_version_id WHERE v.availability='available'"
            )
            |> Enum.map(&story/1),
          "next_cursor" => nil
        }

      {"GET", ["v1", "stories", id]} ->
        r = DB.one("SELECT * FROM stories WHERE id=$1", [DB.uuid(id)])
        Util.require!(r != nil, "RESOURCE_NOT_FOUND")

        Map.merge(story(r), %{
          "current_version_id" => DB.str(r["current_version_id"]),
          "duration_range_ms" => [600_000, 900_000]
        })

      {"POST", ["v1", "rooms"]} ->
        Auth.create_room(ctx(conn), json!(p, ~w(story_id command_id))) |> created()

      {"POST", ["v1", "rooms", "join"]} ->
        Auth.join_room(ctx(conn), json!(p, ~w(invite_code command_id)))

      {"GET", ["v1", "rooms"]} ->
        c = ctx(conn)

        rs =
          DB.rows(
            "SELECT r.id,r.lifecycle,r.updated_at FROM rooms r JOIN room_members m ON m.room_id=r.id WHERE m.user_id=$1 ORDER BY r.updated_at DESC LIMIT 100",
            [DB.uuid(c.user)]
          )

        %{
          "items" =>
            Enum.map(
              rs,
              &%{
                "room_id" => DB.str(&1["id"]),
                "title" => "末班车的第七位乘客",
                "lifecycle" => &1["lifecycle"],
                "can_resume" => &1["lifecycle"] in ["paused", "suspended"],
                "updated_at" => Util.iso(&1["updated_at"])
              }
            ),
          "next_cursor" => nil
        }

      {"POST", ["v1", "rooms", rid, "socket-ticket"]} ->
        Auth.ticket(ctx(conn), rid, json!(p, ~w(device_id takeover), ~w(command_id)))

      {"POST", ["v1", "rooms", rid, "invites"]} ->
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

      {"GET", ["v1", "rooms", rid, "snapshot"]} ->
        Store.snapshot(private(conn, rid))

      {"GET", ["v1", "rooms", rid, "events"]} ->
        q = fetch_query_params(conn).query_params

        Store.events(
          private(conn, rid),
          String.to_integer(q["after_seq"] || "0"),
          q["recovery_epoch"],
          if(q["through_seq"], do: String.to_integer(q["through_seq"]), else: nil),
          String.to_integer(q["limit"] || "200")
        )

      {"GET", ["v1", "rooms", rid, "watermark"]} ->
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

      {"GET", ["v1", "rooms", rid, "commands", cid]} ->
        Store.receipt(private(conn, rid), cid)

      {"POST", ["v1", "media", "access"]} ->
        json!(p, ~w(room_id asset_id device_id control_generation))
        origin = System.get_env("PUBLIC_API_URL", "#{conn.scheme}://#{conn.host}:#{conn.port}")
        Ruxi.Media.access(ctx(conn), p, origin)

      {"POST", ["v1", "admin", "auth", "exchange"]} ->
        Auth.admin_exchange(json!(p, ~w(login_code device_id login_request_id)))

      {"POST", ["v1", "admin", "auth", "refresh"]} ->
        Auth.refresh(json!(p, ~w(refresh_token device_id refresh_request_id)), "admin")

      {"POST", ["v1", "admin", "auth", "logout"]} ->
        Auth.logout(ctx(conn, "admin"))

      {_, ["v1", "admin" | rest]} ->
        Ruxi.Admin.dispatch(method, rest, p, ctx(conn, "admin"))

      {"POST", ["internal", "work" | rest]} ->
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

  defp story(r),
    do: %{
      "story_id" => DB.str(r["id"]),
      "title" => r["title"],
      "summary" => r["summary"],
      "seat_count" => r["seat_count"],
      "availability" => "available",
      "cover_url" => nil
    }

  defp created({:ok, v}), do: {:created, v}
  defp created(v), do: v

  defp error(conn, code) do
    status =
      cond do
        code in ~w(UNAUTHORIZED AUTH_EXPIRED) -> 401
        code in ~w(RESOURCE_NOT_FOUND COMMAND_NOT_FOUND) -> 404
        code in ~w(NOT_ALLOWED NOT_MEMBER CONTROL_REPLACED) -> 403
        code == "SERVICE_UNAVAILABLE" -> 503
        code == "INVALID_ARGUMENT" -> 400
        true -> 409
      end

    e = Util.error(code, status == 503)

    conn
    |> put_resp_header("x-request-id", e["trace_id"])
    |> put_resp_header("cache-control", "no-store")
    |> send_json(status, %{"error" => e})
  end

  defp send_json(conn, status, value),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
end
