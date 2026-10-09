defmodule Ruxi.C3.World do
  @moduledoc "Directed passages and per-role observed topology, independent of live barriers."
  alias Ruxi.C3.Interactions, as: I

  def links(s) do
    if s["engine_version"] == 3 do
      Enum.flat_map(I.profile(s["content"])["passages"] || [], fn p ->
        for dir <- ~w(ab ba), d = p[dir], d != nil do
          {from, to} = if dir == "ab", do: {p["a"], p["b"]}, else: {p["b"], p["a"]}

          %{
            "id" => p["id"] <> "_" <> dir,
            "passage_id" => p["id"],
            "from" => from,
            "to" => to,
            "cost" => d["cost"],
            "condition" => %{"op" => "all", "args" => []},
            "direction" => d,
            "barrier_id" => p["barrier_id"],
            "discovered" => true,
            "required_participants" =>
              get_in(s, ["content", "c3_settings", "passage_groups", p["id"]]) || 1
          }
        end
      end)
    else
      s["content"]["links"]
    end
  end

  def traversable?(s, l, r, now) do
    legacy = get_in(s, ["content", "c3_settings", "legacy_passage_conditions", l["id"], "enter"])

    l["direction"]["enabled"] and I.condition(s, l["direction"]["enter_if"], r, now) and
      (is_nil(legacy) or Ruxi.C2.Engine.condition(s, legacy, r, now))
  end

  defp legacy_discovered?(s, l, r, now) do
    condition =
      get_in(s, ["content", "c3_settings", "legacy_passage_conditions", l["id"], "discover"])

    is_nil(condition) or Ruxi.C2.Engine.condition(s, condition, r, now)
  end

  def init(s, now) do
    if s["engine_version"] == 3 do
      s =
        Map.update!(s, "actors", fn actors ->
          Map.new(actors, fn {r, a} ->
            {r,
             Map.merge(a, %{
               "map_observations" => %{},
               "visited_locations" => [a["location"]],
               "known_locations" =>
                 Enum.uniq(
                   a["known_locations"] ++
                     (get_in(s, ["content", "c3_settings", "initial_known_locations", r]) || [])
                 )
             })}
          end)
        end)

      observe(s, now)
    else
      s
    end
  end

  def observe(s, now) do
    if s["engine_version"] == 3 do
      Map.update!(s, "actors", fn actors ->
        Map.new(actors, fn {r, a} ->
          known = a["known_locations"]
          mode = I.profile(s["content"])["map_mode"]

          nearby =
            Enum.filter(
              links(s),
              &(&1["from"] == a["location"] and
                  I.condition(s, &1["direction"]["discover_if"], r, now) and
                  legacy_discovered?(s, &1, r, now))
            )

          known =
            if mode in ~w(explore mixed),
              do: Enum.uniq(known ++ Enum.map(nearby, & &1["to"])),
              else: known

          observations =
            Enum.reduce(nearby, a["map_observations"], fn l, acc ->
              if l["to"] in known,
                do:
                  Map.put(acc, l["id"], %{
                    "allowed" => traversable?(s, l, r, now),
                    "last_seen_tick" => s["round"]
                  }),
                else: acc
            end)

          {r,
           Map.merge(a, %{
             "known_locations" => known,
             "map_observations" => observations,
             "visited_locations" => Enum.uniq([a["location"] | a["visited_locations"]])
           })}
        end)
      end)
    else
      s
    end
  end

  def projected_links(s, r, now) do
    a = s["actors"][r]

    links(s)
    |> Enum.filter(fn l ->
      l["from"] in a["known_locations"] and l["to"] in a["known_locations"] and
        Map.has_key?(a["map_observations"], l["id"])
    end)
    |> Enum.map(fn l ->
      observed = a["map_observations"][l["id"]]

      Map.take(l, ~w(id from to cost passage_id))
      |> Map.merge(%{
        "allowed_now" => l["from"] == a["location"] and traversable?(s, l, r, now),
        "observed_state" => if(observed["allowed"], do: "open", else: "blocked"),
        "last_seen_tick" => observed["last_seen_tick"],
        "needs_confirmation" => l["from"] != a["location"]
      })
    end)
  end

  def arrival(s, a, roles, now) do
    if a["link"] && a["link"]["direction"] do
      rules = get_in(s, ["content", "c3_settings", "arrival_rules"]) || %{}

      effects =
        Enum.flat_map(a["link"]["direction"]["arrival_events"], &Map.get(rules, &1, []))
        |> Enum.map(&I.translate/1)

      s =
        Enum.reduce(effects, s, fn e, acc ->
          Ruxi.C2.Engine.apply_effects(acc, [e], hd(roles), now)
        end)

      observe(s, now)
    else
      s
    end
  end
end
