defmodule Ruxi.TelemetryTest do
  use ExUnit.Case
  alias Ruxi.{DB, Auth, Util, Telemetry}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    {:ok, auth} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
    %{ctx: Auth.authenticate(auth["access_token"])}
  end

  def event,
    do: %{
      "event_id" => Util.id(),
      "session_id" => Util.id(),
      "schema_version" => 1,
      "event_name" => "connection_state",
      "app_version" => "0.1.0",
      "occurred_at" => Util.iso(Util.now()),
      "properties" => %{"state" => "offline"}
    }

  def batch(events), do: %{"batch_id" => Util.id(), "events" => events}

  test "retry uses event identity without double counting", %{ctx: ctx} do
    e = event()
    p = batch([e, e])
    assert {:ok, %{"accepted_ids" => [id], "rejected" => []}} = Telemetry.receive_batch(ctx, p)
    assert id == e["event_id"]
    assert {:ok, _} = Telemetry.receive_batch(ctx, p)

    assert DB.one("SELECT count(*) AS n FROM telemetry_events WHERE user_id=$1", [
             DB.uuid(ctx.user)
           ])["n"] == 1
  end

  test "secret and unknown properties are individually rejected, valid siblings survive", %{
    ctx: ctx
  } do
    good = event()
    secret = put_in(event(), ["properties", "clue_text"], "private")
    unknown = Map.put(event(), "event_name", "game_finished")

    assert {:ok, %{"accepted_ids" => [id], "rejected" => rejected}} =
             Telemetry.receive_batch(ctx, batch([good, secret, unknown]))

    assert id == good["event_id"]
    assert length(rejected) == 2
    assert Enum.all?(rejected, &(&1["code"] == "INVALID_ARGUMENT"))

    assert DB.one("SELECT count(*) AS n FROM telemetry_events WHERE user_id=$1", [
             DB.uuid(ctx.user)
           ])["n"] == 1
  end

  test "oversized batches fail; stale or malformed events never reach retained storage", %{
    ctx: ctx
  } do
    assert {:error, "INVALID_ARGUMENT"} ==
             catch_throw(Telemetry.receive_batch(ctx, batch(List.duplicate(event(), 51))))

    e = Map.put(event(), "occurred_at", Util.iso(Util.now() - 8 * 86_400_000))

    assert {:ok, %{"accepted_ids" => [], "rejected" => rejected}} =
             Telemetry.receive_batch(ctx, batch([e, nil, %{"event_id" => "secret"}]))

    assert length(rejected) == 3
    refute Jason.encode!(rejected) =~ "secret"
  end
end
