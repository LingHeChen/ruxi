defmodule Ruxi.C3.Validation do
  alias Ruxi.C2.Content
  alias Ruxi.C3.Interactions, as: I

  def validate(s) do
    locations = Map.keys(Content.index(s, "locations"))
    barriers = get_in(s, ["c3_settings", "barriers"]) || %{}
    rules = get_in(s, ["c3_settings", "arrival_rules"]) || %{}
    passages = I.profile(s)["passages"]

    problems =
      for {p, n} <- Enum.with_index(passages), reduce: [] do
        errors ->
          errors ++
            check(p["a"] in locations and p["b"] in locations, "/c3/passages/#{n}") ++
            Enum.flat_map(~w(ab ba), fn dir ->
              d = p[dir]

              if d do
                check(d["cost"] > 0, "/c3/passages/#{n}/#{dir}/cost") ++
                  condition(s, d["discover_if"], "/c3/passages/#{n}/#{dir}/discover_if") ++
                  condition(s, d["enter_if"], "/c3/passages/#{n}/#{dir}/enter_if") ++
                  Enum.flat_map(d["arrival_events"], fn id ->
                    check(Map.has_key?(rules, id), "/c3/passages/#{n}/#{dir}/arrival_events")
                  end)
              else
                []
              end
            end)
      end

    role_ids = Map.keys(Content.index(s, "roles"))

    extra =
      check(
        (get_in(s, ["c3_settings", "min_players"]) || length(role_ids)) <= length(role_ids),
        "/c3_settings/min_players"
      ) ++
        check(
          Enum.all?(
            get_in(s, ["c3_settings", "team_decisions"]) || [],
            &Map.has_key?(Content.index(s, "actions"), &1)
          ),
          "/c3_settings/team_decisions"
        ) ++
        Enum.flat_map(get_in(s, ["c3_settings", "objectives"]) || [], fn o ->
          Content.validate_condition(s, o["condition"]) ++
            check(Enum.all?(o["role_ids"], &(&1 in role_ids)), "/c3_settings/objectives")
        end)

    extra =
      extra ++
        Enum.flat_map(get_in(s, ["c3_settings", "initial_known_locations"]) || %{}, fn {r, ls} ->
          check(
            r in role_ids and Enum.all?(ls, &(&1 in locations)),
            "/c3_settings/initial_known_locations"
          )
        end)

    extra =
      extra ++
        Enum.flat_map(get_in(s, ["c3_settings", "memberships"]) || %{}, fn {r, f} ->
          check(
            r in role_ids and f in (get_in(s, ["c3_settings", "factions"]) || []),
            "/c3_settings/memberships"
          )
        end)

    links = for p <- passages, dir <- ~w(ab ba), p[dir] != nil, do: p["id"] <> "_" <> dir

    extra =
      extra ++
        Enum.flat_map(get_in(s, ["c3_settings", "npcs"]) || [], fn n ->
          check(n["location"] in locations, "/c3_settings/npcs") ++
            Enum.flat_map(n["schedule"], fn entry ->
              check(entry["link_id"] in links, "/c3_settings/npcs/schedule")
            end)
        end)

    extra =
      extra ++
        Enum.flat_map(get_in(s, ["c3_settings", "legacy_passage_conditions"]) || %{}, fn {id, cs} ->
          check(id in links, "/c3_settings/legacy_passage_conditions") ++
            Content.validate_condition(s, cs["enter"]) ++
            Content.validate_condition(s, cs["discover"])
        end)

    extra ++
      problems ++
      check(length(Enum.uniq(Enum.map(passages, & &1["id"]))) == length(passages), "/c3/passages") ++
      Enum.flat_map(barriers, fn {_, v} ->
        check(v in ~w(open blocked destroyed), "/c3_settings/barriers")
      end) ++
      Enum.flat_map(rules, fn {id, effects} ->
        if is_list(effects),
          do: Enum.flat_map(effects, &effect(s, &1, "/c3_settings/arrival_rules/#{id}")),
          else: check(false, "/c3_settings/arrival_rules/#{id}")
      end) ++
      Enum.flat_map(I.definitions(s), fn i ->
        case i["kind"] do
          "check" ->
            Enum.flat_map(
              i["modifiers"],
              fn m ->
                condition(s, m["when"], "/c3/interactions/#{i["id"]}/modifiers") ++
                  check(
                    m["when"]["op"] in ~w(always known) or
                      m["when"]["ref"] in ~w(role actor.ap actor.location),
                    "/c3/interactions/#{i["id"]}/modifiers/visibility"
                  )
              end
            )

          "password" ->
            secret = (s["secrets"] || %{})[i["answer_secret_ref"]]

            if is_map(secret) do
              aliases = secret["aliases"] || []

              check(
                is_list(aliases) and
                  Enum.all?([secret["answer"] | aliases], &I.valid_input?(i, &1)),
                "/secrets/#{i["answer_secret_ref"]}"
              )
            else
              []
            end
        end
      end)
  end

  def condition(_, %{"op" => "always"}, _), do: []

  def condition(s, %{"op" => "known", "ref" => ref}, p),
    do: check(Map.has_key?(Content.index(s, "clues"), ref), p)

  def condition(s, %{"op" => "eq", "ref" => "role", "value" => v}, p),
    do: check(Map.has_key?(Content.index(s, "roles"), v), p)

  def condition(s, %{"op" => "eq", "ref" => ref, "value" => v}, p) do
    value =
      cond do
        String.starts_with?(ref, "world.") ->
          Map.get(s["initial"]["world"], String.replace_prefix(ref, "world.", ""), :missing)

        ref == "clock.round" or ref == "actor.ap" ->
          1

        ref == "actor.location" ->
          ""

        true ->
          get_in(s, ["c3_settings", "barriers", ref]) || :missing
      end

    check(value != :missing and type(value) == type(v), p)
  end

  def condition(_, _, p), do: check(false, p)

  def effect(s, e, p) do
    valid =
      case e["op"] do
        "set_barrier" ->
          Map.has_key?(get_in(s, ["c3_settings", "barriers"]) || %{}, e["ref"]) and
            e["value"] in ~w(open blocked destroyed)

        "set_flag" ->
          Map.has_key?(s["initial"]["world"], e["ref"]) and
            type(e["value"]) == type(s["initial"]["world"][e["ref"]])

        "grant_item" ->
          Map.has_key?(Content.index(s, "objects"), e["ref"])

        op when op in ~w(reveal leave_trace) ->
          Map.has_key?(Content.index(s, "clues"), e["ref"])

        "reset_attempts" ->
          Enum.any?(I.definitions(s), &(&1["id"] == e["ref"]))

        _ ->
          false
      end

    check(valid, p)
  end

  defp type(v) when is_integer(v), do: :integer
  defp type(v) when is_boolean(v), do: :boolean
  defp type(v) when is_binary(v), do: :string
  defp type(_), do: :invalid
  defp check(true, _), do: []
  defp check(_, p), do: [I.error("C3_REFERENCE_INVALID", p)]
end
