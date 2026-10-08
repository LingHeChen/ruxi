defmodule Ruxi.Preview do
  @moduledoc "Editor-only sandbox; the same rules and projector, no live room writes."
  alias Ruxi.{Auth, Rules, Util, Contract}

  def create(version, owner, now \\ Util.now()) do
    graph = version["graph"] || Ruxi.Content.demo_graph()
    roles = graph["roles"]
    host = hd(roles)
    ids = Map.new(roles, &{&1, Util.id()})
    state = Rules.initial(Util.id(), Ruxi.DB.str(version["id"]), ids[host], now, graph)

    state =
      Enum.reduce(roles, state, fn role, s ->
        id = ids[role]
        s = Rules.add_member(s, id, Util.id(), now)
        s = Rules.presence(s, id, true, now)
        {s, _, _} = Rules.apply(s, id, "select_role", %{"role_code" => role}, now)
        {s, _, _} = Rules.apply(s, id, "ready", %{"ready" => true}, now)
        s
      end)

    {state, _, _} = Rules.apply(state, ids[host], "start", %{}, now)

    encode(%{
      "owner" => owner,
      "version_id" => Ruxi.DB.str(version["id"]),
      "revision" => version["revision"],
      "hash" => version["content_hash"],
      "expires_at" => now + 1_800_000,
      "clock" => now,
      "ids" => ids,
      "state" => state,
      "steps" => 0,
      "history" => []
    })
  end

  def step(token, owner, version, p, real_now \\ Util.now()) do
    data = decode(token)
    Util.require!(data["owner"] == owner, "NOT_ALLOWED")
    Util.require!(data["expires_at"] > real_now, "PREVIEW_EXPIRED")

    Util.require!(
      data["version_id"] == Ruxi.DB.str(version["id"]) and
        data["revision"] == version["revision"] and data["hash"] == version["content_hash"],
      "REVISION_CONFLICT"
    )

    Util.require!(data["steps"] < 500, "PREVIEW_LIMIT")
    data = put_in(data, ["state", "content"], version["graph"] || Ruxi.Content.demo_graph())
    roles = Map.keys(data["ids"])
    Util.require!(p["actor_role"] in roles, "INVALID_ARGUMENT")
    Util.require!(is_map(p["payload"]), "INVALID_ARGUMENT")
    id = data["ids"][p["actor_role"]]
    state = data["state"]
    now = data["clock"]

    {state, now, result} =
      if p["type"] == "advance_time" do
        delta = p["payload"]["delta_ms"]

        Util.require!(
          is_map(p["payload"]) and Map.keys(p["payload"]) == ["delta_ms"] and
            is_integer(delta) and delta in 1..300_000,
          "INVALID_ARGUMENT"
        )

        {Rules.tick(state, now + delta), now + delta, %{"advanced_ms" => delta}}
      else
        command = %{
          "protocol_version" => 1,
          "command_id" => p["command_id"],
          "recovery_epoch" => Util.epoch(),
          "phase_id" => state["phase_id"],
          "control_generation" => 1,
          "type" => p["type"],
          "payload" => p["payload"]
        }

        command =
          if p["type"] == "offer_item",
            do: Map.put(command, "target_version", p["target_version"]),
            else: command

        Contract.command!(command)

        payload =
          if p["type"] == "offer_item",
            do: Map.put(command["payload"], "target_version", p["target_version"]),
            else: command["payload"]

        {next, result, _} =
          Rules.apply(Rules.tick(state, now), id, p["type"], payload, now)

        next =
          if p["type"] == "request_hint" do
            reservation = Rules.member(next, id)["hint_pending"]["reservation"]

            Rules.finish_hint(
              next,
              id,
              reservation,
              Rules.hint_text(next, id, p["payload"]["hint_level"]),
              "template"
            )
          else
            next
          end

        {next, now, result}
      end

    changes =
      Map.new(roles, fn role ->
        before = Rules.project(data["state"], data["ids"][role])
        after_view = Rules.project(state, data["ids"][role])
        {role, Enum.filter(Map.keys(after_view), &(before[&1] != after_view[&1])) |> Enum.sort()}
      end)

    event = %{
      "step" => data["steps"] + 1,
      "actor_role" => p["actor_role"],
      "type" => p["type"],
      "changed_fields" => changes
    }

    data =
      Map.merge(data, %{
        "state" => state,
        "clock" => now,
        "steps" => data["steps"] + 1,
        "history" => Enum.take(data["history"] ++ [event], -50)
      })

    encode(data) |> Map.put("result", result)
  end

  def version_id(token), do: decode(token)["version_id"]

  defp decode(token) do
    try do
      Util.require!(is_binary(token) and byte_size(token) <= 65_536, "INVALID_ARGUMENT")
      data = Base.url_decode64!(token, padding: false) |> Auth.unseal()

      if data["compressed"] do
        encoded = Base.decode64!(data["compressed"]) |> :zlib.uncompress()
        Util.require!(byte_size(encoded) <= 1_048_576, "PREVIEW_LIMIT")
        Jason.decode!(encoded)
      else
        data
      end
    rescue
      _ -> Util.fail("INVALID_ARGUMENT")
    end
  end

  defp encode(data) do
    token_data = Map.update!(data, "state", &Map.delete(&1, "content"))
    compressed = Jason.encode!(token_data) |> :zlib.compress() |> Base.encode64()
    token = Base.url_encode64(Auth.seal(%{"compressed" => compressed}), padding: false)
    Util.require!(byte_size(token) <= 60_000, "PREVIEW_LIMIT")

    %{
      "preview_token" => token,
      "version_id" => data["version_id"],
      "revision" => data["revision"],
      "server_time" => Util.iso(data["clock"]),
      "steps" => data["steps"],
      "history" => data["history"],
      "views" =>
        Map.new(Map.keys(data["ids"]), &{&1, Rules.project(data["state"], data["ids"][&1])})
    }
  end
end
