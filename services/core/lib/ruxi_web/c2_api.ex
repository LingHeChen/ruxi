defmodule RuxiWeb.C2API do
  import Plug.Conn
  alias Ruxi.{Auth, DB, Util}
  alias Ruxi.C2.{Studio, Store}

  def call(conn) do
    try do
      conn = fetch_query_params(conn)
      data = unwrap(dispatch(conn, conn.method, Enum.drop(conn.path_info, 2)))

      json(conn, 200, %{
        "data" => data,
        "meta" => %{"trace_id" => Util.id(), "server_time" => DB.time(), "protocol_version" => 2}
      })
    rescue
      _ in [ArgumentError, Ecto.CastError] -> failure(conn, "INVALID_ARGUMENT")
    catch
      {:error, code} -> failure(conn, code)
    end
  end

  defp dispatch(c, method, ["studio" | rest]), do: dispatch(c, method, rest)

  defp dispatch(c, method, ["admin", "releases" | rest]),
    do: dispatch(c, method, ["releases" | rest])

  defp dispatch(c, "GET", ["games"]), do: Store.games(ctx(c))

  defp dispatch(c, "POST", ["session", "socket-ticket"]),
    do: Store.ticket(ctx(c), body(c)["room_id"])

  defp dispatch(c, "POST", ["session", "control"]),
    do: Store.ticket(ctx(c), body(c)["room_id"], true)

  defp dispatch(c, "POST", ["projects", id, "preview"]),
    do: mutate(c, fn ctx, p -> Studio.preview(ctx, id, p) end, "admin")

  defp dispatch(c, "GET", ["stories"]), do: Store.list_stories(c.query_params)
  defp dispatch(_, "GET", ["stories", id]), do: Store.story(id)
  defp dispatch(c, "GET", ["me", "games"]), do: Store.games(ctx(c))
  defp dispatch(c, "POST", ["rooms"]), do: mutate(c, fn ctx, p -> Store.create(ctx, p) end)
  defp dispatch(c, "POST", ["rooms", "join"]), do: mutate(c, fn ctx, p -> Store.join(ctx, p) end)

  defp dispatch(c, "POST", ["rooms", id, "socket-ticket"]),
    do: Store.ticket(ctx(c), id, body(c)["takeover"] == true)

  defp dispatch(c, "GET", ["rooms", id, "snapshot"]), do: Store.snapshot(ctx(c), id)
  defp dispatch(c, "POST", ["rooms", id, "commands"]), do: Store.command(ctx(c), id, body(c))

  defp dispatch(c, "GET", ["rooms", id, "commands", command]),
    do: Store.command_result(ctx(c), id, command)

  defp dispatch(c, "GET", ["projects"]), do: Studio.list(ctx(c, "admin"))
  defp dispatch(c, "POST", ["projects"]), do: mutate(c, &Studio.create/2, "admin")
  defp dispatch(c, "GET", ["projects", id]), do: Studio.get(ctx(c, "admin"), id)
  defp dispatch(c, "GET", ["projects", id, "draft"]), do: Studio.draft(ctx(c, "admin"), id)

  defp dispatch(c, "PUT", ["projects", id, "draft"]),
    do: mutate(c, fn ctx, p -> Studio.save(ctx, id, p["content"], revision(c)) end, "admin")

  defp dispatch(c, "GET", ["projects", id, "layout"]), do: Studio.layout(ctx(c, "admin"), id)

  defp dispatch(c, "PUT", ["projects", id, "layout"]),
    do: mutate(c, fn ctx, p -> Studio.save_layout(ctx, id, p["layout"], revision(c)) end, "admin")

  defp dispatch(c, "POST", ["projects", id, "validate"]),
    do: mutate(c, fn ctx, _ -> Studio.validate(ctx, id) end, "admin")

  defp dispatch(c, "POST", ["projects", id, "reviews"]),
    do: mutate(c, fn ctx, p -> Studio.review(ctx, id, p) end, "admin")

  defp dispatch(c, "GET", ["projects", id, "releases"]), do: Studio.releases(ctx(c, "admin"), id)

  defp dispatch(c, "POST", ["projects", id, "releases"]),
    do: mutate(c, fn ctx, p -> Studio.publish(ctx, id, p) end, "admin")

  defp dispatch(c, "POST", ["projects", id, "archive"]),
    do: mutate(c, fn ctx, _ -> Studio.archive(ctx, id) end, "admin")

  defp dispatch(c, "PATCH", ["projects", id]),
    do: mutate(c, fn ctx, p -> Studio.metadata(ctx, id, p, revision(c)) end, "admin")

  defp dispatch(c, "GET", ["projects", id, "export"]), do: Studio.export(ctx(c, "admin"), id)

  defp dispatch(c, "POST", ["projects", "import"]),
    do: mutate(c, &Studio.import/2, "admin")

  defp dispatch(c, "POST", ["projects", id, "previews"]),
    do: mutate(c, fn ctx, p -> Studio.preview(ctx, id, p) end, "admin")

  defp dispatch(c, "POST", ["previews", id, "commands"]),
    do: mutate(c, fn ctx, p -> Studio.preview_step(ctx, id, p) end, "admin")

  defp dispatch(c, "POST", ["releases", id, action]) when action in ["withdraw", "block"],
    do: mutate(c, fn ctx, p -> Studio.withdraw(ctx, id, p, action == "block") end, "admin")

  defp dispatch(_, _, _), do: Util.fail("RESOURCE_NOT_FOUND")

  defp ctx(c, audience \\ "player") do
    case get_req_header(c, "authorization") do
      ["Bearer " <> token] -> Auth.authenticate(token, audience)
      _ -> Util.fail("UNAUTHORIZED")
    end
  end

  defp body(c) do
    Util.require!(
      is_map(c.body_params) and not match?(%Plug.Conn.Unfetched{}, c.body_params),
      "INVALID_ARGUMENT"
    )

    c.body_params
  end

  defp mutate(c, fun, audience \\ "player") do
    p = body(c)
    key = List.first(get_req_header(c, "idempotency-key"))
    Util.require!(is_binary(key) and byte_size(key) in 1..128, "IDEMPOTENCY_KEY_REQUIRED")
    id = Ecto.UUID.cast!(binary_part(:crypto.hash(:sha256, key), 0, 16))
    p = p |> Map.put("command_id", id) |> Map.put("__if_match", get_req_header(c, "if-match"))

    Auth.account(ctx(c, audience), "c2:" <> c.method <> ":" <> c.request_path, p, fn ->
      fun.(ctx(c, audience), p)
    end)
  end

  defp revision(c) do
    case get_req_header(c, "if-match") do
      [] ->
        Util.fail("PRECONDITION_REQUIRED")

      [value] ->
        case Integer.parse(String.trim(value, "\"")) do
          {n, ""} when n > 0 -> n
          _ -> Util.fail("INVALID_ARGUMENT")
        end

      _ ->
        Util.fail("INVALID_ARGUMENT")
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, code}), do: Util.fail(code)
  defp unwrap(value), do: value

  defp failure(c, code) do
    status =
      case code do
        "UNAUTHORIZED" -> 401
        "RESOURCE_NOT_FOUND" -> 404
        "PRECONDITION_REQUIRED" -> 428
        "REVISION_CONFLICT" -> 412
        "FORBIDDEN" -> 403
        "NOT_ALLOWED" -> 403
        "IDEMPOTENCY_CONFLICT" -> 409
        "OWNER_UNAVAILABLE" -> 503
        _ -> 400
      end

    json(c, status, %{
      "error" => %{
        "code" => code,
        "safe_message" => "操作未完成，请检查当前状态后重试",
        "retryable" => code == "OWNER_UNAVAILABLE",
        "trace_id" => Util.id()
      },
      "meta" => %{"trace_id" => Util.id(), "protocol_version" => 2}
    })
  end

  defp json(c, status, data),
    do:
      c
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(data))
end
