defmodule Ruxi.Telemetry do
  @moduledoc "Optional diagnostics, never authoritative business success metrics."
  alias Ruxi.{DB, Util, Auth}

  @allowed %{
    "screen_view" => {"screen", ~w(entry discover lobby play ending account)},
    "connection_state" => {"state", ~w(online offline reconnecting)},
    "media_summary" => {"reason", ~w(timeout buffering user)},
    "command_attempt" =>
      {"kind",
       ~w(select_role ready start media_complete investigate share_clue offer_item accept_offer reject_offer cancel_offer vote request_hint chat_send request_pause confirm_pause cancel_pause resume leave_room)}
  }

  def receive_batch(ctx, p) do
    RuxiWeb.Router.json!(p, ~w(batch_id events))
    Util.require!(Ruxi.Contract.uuid?(p["batch_id"]), "INVALID_ARGUMENT")

    Util.require!(
      is_list(p["events"]) and length(p["events"]) in 1..50 and
        byte_size(Jason.encode!(p)) <= 65_536,
      "INVALID_ARGUMENT"
    )

    now = Util.now()

    {events, rejected} =
      Enum.reduce(p["events"], {[], []}, fn e, {valid, invalid} ->
        try do
          {[validate!(e, now) | valid], invalid}
        rescue
          _ in [ArgumentError, Protocol.UndefinedError] ->
            {valid, [%{"event_id" => nil, "code" => "INVALID_ARGUMENT"} | invalid]}
        catch
          {:error, code} ->
            id = if is_map(e) and Ruxi.Contract.uuid?(e["event_id"]), do: e["event_id"], else: nil
            {valid, [%{"event_id" => id, "code" => code} | invalid]}
        end
      end)

    Ruxi.Limiter.check!({:telemetry, ctx.user}, 0.5, 5)

    DB.transaction(fn ->
      DB.one("SELECT id FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(ctx.user)])
      Auth.valid!(ctx)

      for {e, occurred} <- events do
        DB.query(
          """
          INSERT INTO telemetry_events(event_id,user_id,session_id,event_name,schema_version,app_version,occurred_at,properties)
          VALUES($1,$2,$3,$4,1,$5,$6,$7) ON CONFLICT(event_id) DO NOTHING
          """,
          [
            DB.uuid(e["event_id"]),
            DB.uuid(ctx.user),
            DB.uuid(e["session_id"]),
            e["event_name"],
            e["app_version"],
            occurred,
            e["properties"]
          ]
        )
      end

      %{
        "accepted_ids" => Enum.map(events, fn {e, _} -> e["event_id"] end) |> Enum.uniq(),
        "rejected" => Enum.reverse(rejected)
      }
    end)
  end

  defp validate!(e, now) do
    RuxiWeb.Router.json!(
      e,
      ~w(event_id event_name schema_version occurred_at app_version session_id properties)
    )

    Util.require!(
      Ruxi.Contract.uuid?(e["event_id"]) and Ruxi.Contract.uuid?(e["session_id"]) and
        e["schema_version"] == 1 and is_binary(e["app_version"]) and
        Regex.match?(~r/\A[0-9][A-Za-z0-9.+-]{0,31}\z/, e["app_version"]) and
        is_binary(e["occurred_at"]),
      "INVALID_ARGUMENT"
    )

    {field, values} = Map.get(@allowed, e["event_name"], {nil, []})
    properties = e["properties"]

    Util.require!(
      field != nil and is_map(properties) and Map.keys(properties) == [field] and
        properties[field] in values,
      "INVALID_ARGUMENT"
    )

    occurred =
      case DateTime.from_iso8601(e["occurred_at"]) do
        {:ok, date, _} -> date
        _ -> Util.fail("INVALID_ARGUMENT")
      end

    ms = DateTime.to_unix(occurred, :millisecond)
    Util.require!(ms >= now - 7 * 86_400_000 and ms <= now + 300_000, "INVALID_ARGUMENT")
    {e, occurred}
  end
end
