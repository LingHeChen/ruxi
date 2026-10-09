defmodule Ruxi.C2.APITest do
  use ExUnit.Case
  import Plug.Conn
  alias Ruxi.{Auth, DB, Util}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    {:ok, a} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    ctx = Auth.authenticate(a["access_token"])
    DB.query("UPDATE sessions SET audience='admin' WHERE id=$1", [DB.uuid(ctx.session)])
    DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,'editor')", [DB.uuid(ctx.user)])
    %{token: a["access_token"]}
  end

  def request(method, path, body, token, headers \\ []) do
    c =
      Plug.Test.conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    c = Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end)
    c = Plug.Parsers.call(c, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    RuxiWeb.Router.call(c, RuxiWeb.Router.init([]))
  end

  test "project HTTP mutations enforce idempotency and If-Match", %{token: t} do
    p = %{"title" => "新世界", "seat_count" => 2}
    assert request("POST", "/api/v2/projects", p, t).status == 400
    headers = [{"idempotency-key", Util.id()}]
    a = request("POST", "/api/v2/projects", p, t, headers)
    assert a.status == 200
    id = Jason.decode!(a.resp_body)["data"]["id"]
    b = request("POST", "/api/v2/projects", p, t, headers)
    assert Jason.decode!(b.resp_body)["data"]["id"] == id

    draft =
      request("GET", "/api/v2/projects/#{id}/draft", %{}, t)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    graph = draft["data"]["content"]

    assert request("PUT", "/api/v2/projects/#{id}/draft", %{"content" => graph}, t, [
             {"idempotency-key", Util.id()}
           ]).status == 428

    h = [{"idempotency-key", Util.id()}, {"if-match", "1"}]

    assert request("PUT", "/api/v2/projects/#{id}/draft", %{"content" => graph}, t, h).status ==
             200

    assert request("PUT", "/api/v2/projects/#{id}/draft", %{"content" => graph}, t, [
             {"idempotency-key", Util.id()},
             {"if-match", "1"}
           ]).status == 412
  end
end
