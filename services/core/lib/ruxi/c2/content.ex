defmodule Ruxi.C2.Content do
  @moduledoc "C2 compilation validates references, types and audience boundaries independently of the editor."
  alias Ruxi.C2.Schema
  @collections ~w(roles locations links objects clues actions templates events media votes)
  def validate(%{"schema_version" => 4} = story), do: Ruxi.C3.Interactions.validate(story)

  def validate(story) do
    errors = Schema.validate(story, Schema.load("story"))
    errors = if errors == [], do: semantic(story), else: errors

    %{
      "valid" => errors == [],
      "schema_version" => 3,
      "errors" => errors,
      "hash" => if(errors == [], do: Ruxi.Util.hash(story), else: nil)
    }
  end

  def validate_c3_base(story) do
    schema =
      Application.app_dir(:ruxi, "priv/c3/story.schema.json") |> File.read!() |> Jason.decode!()

    errors = Schema.validate(story, schema)
    if errors == [], do: semantic(story), else: errors
  end

  def validate_condition(story, c),
    do:
      condition(
        c,
        story,
        Map.new(@collections, &{&1, index(story, &1)}),
        "/c3_settings",
        false,
        0
      )

  def compile!(story) do
    report = validate(story)
    if report["valid"], do: story, else: Ruxi.Util.fail("CONTENT_INVALID")
  end

  def index(story, kind), do: Map.new(story[kind] || [], &{&1["id"], &1})

  defp issue(code, pointer),
    do: [%{"code" => code, "pointer" => pointer, "message" => messages(code)}]

  defp messages("UNKNOWN_REFERENCE"), do: "引用的实体不存在"
  defp messages("TYPE_MISMATCH"), do: "变量或比较值类型不一致"
  defp messages("UNSAFE_AUDIENCE"), do: "全局事件或媒体受众超出允许范围"
  defp messages("MISSING_FALLBACK"), do: "缺少轮次截止后的兜底结局"
  defp messages(_), do: "内容规则不符合规范"

  defp require_ref(ref, ids, path),
    do: if(Map.has_key?(ids, ref), do: [], else: issue("UNKNOWN_REFERENCE", path))

  defp semantic(s) do
    ids = Map.new(@collections, &{&1, index(s, &1)})

    duplicate =
      Enum.flat_map(@collections, fn k ->
        if map_size(ids[k]) == length(s[k] || []), do: [], else: issue("DUPLICATE_ID", "/#{k}")
      end)

    duplicate =
      duplicate ++
        if MapSet.disjoint?(
             MapSet.new(Map.keys(ids["actions"])),
             MapSet.new(Map.keys(ids["templates"]))
           ), do: [], else: issue("DUPLICATE_ID", "/templates")

    locations =
      for k <- ~w(roles objects actions templates),
          {entity, i} <- Enum.with_index(s[k]),
          reduce: [] do
        acc -> acc ++ require_ref(entity["location"], ids["locations"], "/#{k}/#{i}/location")
      end

    links =
      Enum.flat_map(Enum.with_index(s["links"]), fn {x, i} ->
        require_ref(x["from"], ids["locations"], "/links/#{i}/from") ++
          require_ref(x["to"], ids["locations"], "/links/#{i}/to")
      end)

    knowledge =
      Enum.flat_map(Enum.with_index(s["roles"]), fn {r, i} ->
        Enum.flat_map(r["knowledge"], &require_ref(&1, ids["clues"], "/roles/#{i}/knowledge"))
      end)

    inventory =
      Enum.flat_map(s["initial"]["inventory"], fn {r, items} ->
        require_ref(r, ids["roles"], "/initial/inventory/#{r}") ++
          Enum.flat_map(items, &require_ref(&1, ids["objects"], "/initial/inventory/#{r}"))
      end)

    items = s["initial"]["inventory"] |> Map.values() |> List.flatten()

    inventory =
      inventory ++
        if length(items) == MapSet.size(MapSet.new(items)),
          do: [],
          else: issue("DUPLICATE_OWNERSHIP", "/initial/inventory")

    rules =
      Enum.flat_map(~w(actions templates events links), fn k ->
        Enum.flat_map(Enum.with_index(s[k]), fn {x, i} ->
          path = "/#{k}/#{i}"
          global = k == "events" and x["trigger"] in ~w(room_start step_end round_end)
          cond_errors = condition(x["condition"], s, ids, path <> "/condition", global, 0)

          display =
            if x["display_condition"],
              do:
                condition(x["display_condition"], s, ids, path <> "/display_condition", global, 0),
              else: []

          target =
            if k in ~w(actions templates) and x["target"],
              do: require_ref(x["target"], ids["objects"], path <> "/target"),
              else: []

          participants =
            if (x["required_participants"] || 1) > length(s["roles"]),
              do: issue("INVALID_PARTICIPANTS", path),
              else: []

          effect_errors =
            Enum.flat_map(~w(effects failure), fn branch ->
              Enum.flat_map(Enum.with_index(x[branch] || []), fn {e, j} ->
                effect(e, x, k, s, ids, path <> "/#{branch}/#{j}", global)
              end)
            end)

          cond_errors ++ display ++ target ++ participants ++ effect_errors
        end)
      end)

    votes =
      Enum.flat_map(Enum.with_index(s["votes"] || []), fn {v, i} ->
        opts = Map.new(v["options"], &{&1["id"], &1})

        duplicates =
          if map_size(opts) == length(v["options"]),
            do: [],
            else: issue("DUPLICATE_ID", "/votes/#{i}/options")

        defaults = require_ref(v["default_option"], opts, "/votes/#{i}/default_option")

        defaults =
          defaults ++
            if opts[v["default_option"]] &&
                 opts[v["default_option"]]["condition"] != %{"op" => "all", "args" => []},
               do: issue("INVALID_DEFAULT", "/votes/#{i}/default_option"),
               else: []

        duplicates ++
          defaults ++
          Enum.flat_map(Enum.with_index(v["options"]), fn {o, j} ->
            condition(o["condition"], s, ids, "/votes/#{i}/options/#{j}/condition", true, 0) ++
              Enum.flat_map(
                o["effects"],
                &effect(&1, v, "votes", s, ids, "/votes/#{i}/options/#{j}/effects", true)
              )
          end)
      end)

    media =
      Enum.flat_map(Enum.with_index(s["media"]), fn {m, i} ->
        audience =
          if m["audience"] == "public",
            do: [],
            else:
              Enum.flat_map(m["audience"], &require_ref(&1, ids["roles"], "/media/#{i}/audience"))

        audience ++
          if String.trim(m["summary"]) == "",
            do: issue("MISSING_SUMMARY", "/media/#{i}/summary"),
            else: []
      end)

    endings =
      Enum.flat_map(s["events"], fn e -> Enum.filter(e["effects"], &(&1["op"] == "end")) end)

    fallback =
      if Enum.any?(s["events"], fn e ->
           e["trigger"] == "round_end" and
             e["condition"] == %{
               "op" => "gte",
               "ref" => "clock.round",
               "value" => s["rules"]["round_limit"]
             } and Enum.any?(e["effects"], &(&1["op"] == "end"))
         end), do: [], else: issue("MISSING_FALLBACK", "/events")

    missing_end = if endings == [], do: issue("MISSING_ENDING", "/events"), else: []

    duplicate ++
      locations ++
      links ++ knowledge ++ inventory ++ rules ++ votes ++ media ++ fallback ++ missing_end
  end

  defp type(v) when is_boolean(v), do: :boolean
  defp type(v) when is_integer(v), do: :integer
  defp type(v) when is_binary(v), do: :string
  defp type(nil), do: :null
  defp type(_), do: :invalid
  defp condition(_, _, _, path, _, depth) when depth > 12, do: issue("CONDITION_DEPTH", path)

  defp condition(%{"op" => op} = c, s, ids, path, global, depth) when op in ~w(all any not) do
    arity =
      if op == "not" and length(c["args"]) != 1, do: issue("INVALID_CONDITION", path), else: []

    arity ++ Enum.flat_map(c["args"], &condition(&1, s, ids, path, global, depth + 1))
  end

  defp condition(%{"op" => op, "ref" => ref} = c, s, ids, path, global, _) do
    case op do
      "has_knowledge" ->
        require_ref(ref, ids["clues"], path) ++
          if(global, do: issue("UNSAFE_AUDIENCE", path), else: [])

      "owns" ->
        require_ref(ref, ids["objects"], path) ++
          if(global, do: issue("UNSAFE_AUDIENCE", path), else: [])

      _ ->
        {exists, value_type} = ref_type(ref, s)
        errors = if exists, do: [], else: issue("UNKNOWN_REFERENCE", path)

        errors =
          errors ++
            if global and String.starts_with?(ref, "actor."),
              do: issue("UNSAFE_AUDIENCE", path),
              else: []

        errors ++
          if exists and
               (value_type != type(c["value"]) or (op in ~w(gte lte) and value_type != :integer)),
             do: issue("TYPE_MISMATCH", path),
             else: []
    end
  end

  defp ref_type("world." <> key, s),
    do: {Map.has_key?(s["initial"]["world"], key), type(s["initial"]["world"][key])}

  defp ref_type("actor.location", _), do: {true, :string}
  defp ref_type(ref, _) when ref in ~w(actor.ap clock.round), do: {true, :integer}
  defp ref_type(_, _), do: {false, :invalid}

  defp effect(e, owner, kind, s, ids, path, global) do
    private = if global and e["audience"] == "self", do: issue("UNSAFE_AUDIENCE", path), else: []

    private ++
      case e["op"] do
        "set" ->
          {exists, t} = ref_type(e["ref"], s)

          cond do
            not String.starts_with?(e["ref"], "world.") or not exists ->
              issue("UNKNOWN_REFERENCE", path)

            t != type(e["value"]) ->
              issue("TYPE_MISMATCH", path)

            true ->
              []
          end

        "reveal" ->
          require_ref(e["ref"], ids["clues"], path)

        "discover" ->
          require_ref(e["ref"], ids["locations"], path)

        "grant" ->
          require_ref(e["ref"], ids["objects"], path) ++
            if(global, do: issue("UNSAFE_AUDIENCE", path), else: [])

        "destroy" ->
          require_ref(e["ref"], ids["objects"], path) ++
            if(global, do: issue("UNSAFE_AUDIENCE", path), else: [])

        "move" ->
          issue("INVALID_MOVE_EFFECT", path)

        "end" ->
          require_ref(e["value"], ids["media"], path) ++
            if(kind == "events" and owner["trigger"] in ~w(step_end round_end),
              do: [],
              else: issue("INVALID_END_PHASE", path)
            )

        "start_vote" ->
          require_ref(e["ref"], ids["votes"], path) ++
            if(kind == "events" and owner["trigger"] in ~w(step_end round_end),
              do: [],
              else: issue("INVALID_VOTE_PHASE", path)
            )

        "cue" ->
          asset = ids["media"][e["ref"]]

          require_ref(e["ref"], ids["media"], path) ++
            if((asset && e["audience"] == "all") and asset["audience"] != "public",
              do: issue("UNSAFE_AUDIENCE", path),
              else: []
            )
      end
  end
end
