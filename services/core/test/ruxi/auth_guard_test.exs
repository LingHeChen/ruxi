defmodule Ruxi.AuthGuardTest do
  use ExUnit.Case
  alias Ruxi.{AuthGuard, Util}

  test "five failed attempts exhaust the code budget across distinct peers" do
    code = Util.id()

    for _ <- 1..5,
        do:
          assert(
            AuthGuard.run("recover", Util.id(), code, fn -> {:error, "UNAUTHORIZED"} end) ==
              {:error, "UNAUTHORIZED"}
          )

    assert {:error, "RATE_LIMITED", wait} =
             catch_throw(AuthGuard.run("recover", Util.id(), code, fn -> :ok end))

    assert wait in 1..60_000
  end

  test "twenty failures exhaust the peer budget across distinct codes" do
    peer = Util.id()

    for _ <- 1..20,
        do: AuthGuard.run("admin.exchange", peer, Util.id(), fn -> {:error, "UNAUTHORIZED"} end)

    assert {:error, "RATE_LIMITED", _} =
             catch_throw(AuthGuard.run("admin.exchange", peer, Util.id(), fn -> :ok end))
  end

  test "success releases reservations and exceptions count as failures" do
    peer = Util.id()
    code = Util.id()

    for _ <- 1..30,
        do: assert(AuthGuard.run("recover", peer, code, fn -> {:ok, %{}} end) == {:ok, %{}})

    for _ <- 1..5,
        do:
          assert(
            catch_throw(AuthGuard.run("recover", peer, code, fn -> Util.fail("UNAUTHORIZED") end)) ==
              {:error, "UNAUTHORIZED"}
          )

    assert {:error, "RATE_LIMITED", _} =
             catch_throw(AuthGuard.run("recover", peer, code, fn -> :ok end))
  end

  test "HTTP authentication errors become 429 with a bounded retry time" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    code = Util.id()

    body = %{
      "recovery_code" => code,
      "device_id" => Util.id(),
      "recovery_request_id" => Util.id()
    }

    call = fn ->
      conn = Plug.Test.conn(:post, "/v1/auth/recover")
      conn = %{conn | body_params: body}
      RuxiWeb.Router.call(conn, RuxiWeb.Router.init([]))
    end

    for _ <- 1..5, do: assert(call.().status == 401)
    response = call.()
    assert response.status == 429
    assert [_] = Plug.Conn.get_resp_header(response, "retry-after")
    error = Jason.decode!(response.resp_body)["error"]
    assert error["retry_after_ms"] in 1..60_000
    refute response.resp_body =~ code
  end
end
