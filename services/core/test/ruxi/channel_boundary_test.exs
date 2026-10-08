defmodule Ruxi.ChannelBoundaryTest do
  use ExUnit.Case, async: true

  test "non-object intents and clock payloads are rejected without crashing or echoing input" do
    socket = %Phoenix.Socket{assigns: %{}}

    for {event, payload} <- [
          {"command", ["synthetic-private-canary"]},
          {"clock_ping", ["synthetic-private-canary"]},
          {"clock_ping", %{"nonce" => String.duplicate("x", 129)}}
        ] do
      assert {:reply, {:error, %{"error" => error}}, ^socket} =
               RuxiWeb.RoomChannel.handle_in(event, payload, socket)

      assert error["code"] == "INVALID_ARGUMENT"
      refute Jason.encode!(error) =~ "synthetic-private-canary"
    end
  end
end
