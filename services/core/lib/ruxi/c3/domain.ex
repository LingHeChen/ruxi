defmodule Ruxi.C3.Domain do
  @moduledoc "Role-owned knowledge provenance, faction membership, objectives and discrete NPC ticks."
  alias Ruxi.C2.{Engine, Content}
  alias Ruxi.C3.World

  def init(s) do
    if s["engine_version"] == 3 do
      memberships = get_in(s, ["content", "c3_settings", "memberships"]) || %{}

      s =
        Map.merge(s, %{
          "npc_states" =>
            Map.new(get_in(s, ["content", "c3_settings", "npcs"]) || [], fn n ->
              {n["id"], %{"location" => n["location"], "ticks" => []}}
            end),
          "objective_states" => %{}
        })

      Map.update!(s, "actors", fn actors ->
        Map.new(actors, fn {r, a} ->
          faction = memberships[r]

          records =
            Map.new(
              a["knowledge"],
              &{&1,
               %{
                 "category" => "observed",
                 "acquired_tick" => 0,
                 "source" => "开场已知",
                 "provenance" => []
               }}
            )

          {r,
           Map.merge(a, %{
             "faction" => faction,
             "assigned_faction" => faction,
             "knowledge_records" => records
           })}
        end)
      end)
    else
      s
    end
  end

  def knowledge(s, ref, roles, source) do
    if s["engine_version"] == 3 do
      Enum.reduce(roles, s, fn r, acc ->
        record = %{
          "category" => if(source == r, do: "observed", else: "reported"),
          "acquired_tick" => s["round"],
          "source" =>
            if(source == r,
              do: "亲历",
              else:
                (Content.index(s["content"], "roles")[source] || %{"label" => "世界事件"})["label"]
            ),
          "provenance" => if(source == r, do: [], else: [source])
        }

        update_in(acc, ["actors", r, "knowledge_records"], &Map.put_new(&1, ref, record))
      end)
    else
      s
    end
  end

  def objectives(s, r, now) do
    definitions = get_in(s, ["content", "c3_settings", "objectives"]) || []
    a = s["actors"][r]

    Enum.filter(definitions, fn o ->
      faction =
        if o["membership_policy"] == "retain_assigned",
          do: a["assigned_faction"],
          else: a["faction"]

      eligible =
        r in (o["role_ids"] || []) or o["layer"] == "public" or
          (o["faction_id"] != nil and o["faction_id"] == faction)

      eligible and
        not (o["membership_policy"] == "retire" and a["assigned_faction"] != a["faction"])
    end)
    |> Enum.map(fn o ->
      attained =
        get_in(s, ["objective_states", o["id"] <> ":" <> r]) ||
          Engine.condition(s, o["condition"], r, now)

      Map.take(o, ~w(id label layer))
      |> Map.put(
        "result",
        if(s["status"] in ~w(ending finished),
          do: if(attained, do: "achieved", else: "failed"),
          else: "in_progress"
        )
      )
    end)
  end

  def evaluate(s, now) do
    if s["engine_version"] == 3 do
      definitions = get_in(s, ["content", "c3_settings", "objectives"]) || []

      Enum.reduce(definitions, s, fn o, acc ->
        if o["latch"] do
          Enum.reduce(Map.keys(s["actors"]), acc, fn r, next ->
            if Engine.condition(s, o["condition"], r, now),
              do: put_in(next, ["objective_states", o["id"] <> ":" <> r], true),
              else: next
          end)
        else
          acc
        end
      end)
    else
      s
    end
  end

  def tick(s, now) do
    if s["engine_version"] == 3 do
      Enum.reduce(get_in(s, ["content", "c3_settings", "npcs"]) || [], s, fn n, acc ->
        npc = acc["npc_states"][n["id"]]
        schedule = Enum.find(n["schedule"], &(&1["round"] == s["round"]))

        if schedule && s["round"] not in npc["ticks"] do
          link = Enum.find(World.links(acc), &(&1["id"] == schedule["link_id"]))

          next_location =
            if link && link["from"] == npc["location"] && World.traversable?(acc, link, nil, now),
              do: link["to"],
              else: npc["location"]

          put_in(acc, ["npc_states", n["id"]], %{
            "location" => next_location,
            "ticks" => [s["round"] | npc["ticks"]]
          })
        else
          acc
        end
      end)
    else
      s
    end
  end

  def project_npcs(s, r) do
    Enum.filter(get_in(s, ["content", "c3_settings", "npcs"]) || [], fn n ->
      get_in(s, ["npc_states", n["id"], "location"]) == s["actors"][r]["location"]
    end)
    |> Enum.map(&Map.take(&1, ~w(id label description)))
  end
end
