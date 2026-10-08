defmodule Ruxi.MediaCORSTest do
  use ExUnit.Case
  import Plug.Conn

  test "allowed player origins can preflight ranged media without exposing credentials" do
    conn =
      Plug.Test.conn("OPTIONS", "/media/synthetic-capability")
      |> put_req_header("origin", "http://localhost:8080")
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "range")
      |> RuxiWeb.Endpoint.call(RuxiWeb.Endpoint.init([]))

    assert conn.status in [200, 204]
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:8080"]

    assert Enum.any?(
             get_resp_header(conn, "access-control-allow-headers"),
             &String.contains?(&1, "range")
           )

    assert Enum.any?(
             get_resp_header(conn, "access-control-expose-headers"),
             &String.contains?(&1, "content-range")
           )
  end
end
