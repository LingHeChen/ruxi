defmodule Ruxi.ContentAST do
  @moduledoc "Finite white-listed condition/effect compiler and bounded reachability explorer."
  alias Ruxi.Util

  @root ~w(schema_version story_id title seat_count roles phases variables actions decision timing media assets asset_status demo_only role_definitions clues option_labels hints description min_protocol_version)
  @default_clues %{
    "C1" => %{"title" => "车厢名单", "text" => "名单上只有六个名字，却有第七处被擦去的签名。", "shareable" => true},
    "C2" => %{"title" => "旧车票上的时间码", "text" => "手机留言里的时间码是 23:17，与旧车票一致。", "shareable" => false},
    "C3" => %{"title" => "异常装置记录", "text" => "控制柜记录证实，未来留言由车上的异常装置发出。", "shareable" => true}
  }
  def clues(g), do: g["clues"] || @default_clues
  def roles(g), do: g["roles"]
  def initial_vars(g), do: Map.new(g["variables"], fn {k, v} -> {k, v["initial"]} end)

  def compile(g, limit \\ 50_000) do
    try do
      check!(is_map(g) and Enum.all?(Map.keys(g), &(&1 in @root)), "unknown content field")

      check!(
        g["schema_version"] == 2 and g["seat_count"] in 2..4 and is_list(g["roles"]) and
          length(g["roles"]) == g["seat_count"] and unique?(g["roles"]) and
          Enum.all?(g["roles"], &code?/1),
        "invalid seats or roles"
      )

      check!(
        Ruxi.Contract.uuid?(g["story_id"]) and text?(g["title"], 120),
        "invalid story identity"
      )

      check!(
        g["phases"] == ~w(briefing exploration decision),
        "phase graph must be acyclic C1 stages"
      )

      check!(g["min_protocol_version"] in [nil, 1], "unsupported minimum protocol")

      check!(
        g["asset_status"] in ~w(programmatic_demo_ready ready draft missing_original_video) and
          is_boolean(g["demo_only"]),
        "invalid asset state"
      )

      if g["description"], do: check!(text?(g["description"], 2000), "invalid public description")

      if g["role_definitions"] do
        check!(
          is_map(g["role_definitions"]) and
            Enum.all?(Map.keys(g["role_definitions"]), &(&1 in g["roles"])),
          "unknown role definition"
        )

        Enum.each(g["role_definitions"], fn {_, d} ->
          exact!(d, ~w(title description), ~w(public_description))

          check!(
            text?(d["title"], 120) and text?(d["description"], 2000) and
              (is_nil(d["public_description"]) or text?(d["public_description"], 500)),
            "invalid role text"
          )
        end)
      end

      if g["hints"] do
        check!(is_map(g["hints"]), "invalid hint templates")

        Enum.each(g["hints"], fn {role, phases} ->
          check!(
            role in g["roles"] and is_map(phases) and
              Enum.all?(Map.keys(phases), &(&1 in ~w(exploration decision))),
            "invalid hint scope"
          )

          Enum.each(phases, fn {_, levels} ->
            check!(
              is_list(levels) and length(levels) == 2 and Enum.all?(levels, &text?(&1, 2000)),
              "invalid hint levels"
            )
          end)
        end)
      end

      check!(is_map(g["variables"]) and map_size(g["variables"]) <= 20, "invalid variables")

      Enum.each(g["variables"], fn {name, v} ->
        check!(code?(name) and is_map(v), "invalid variable")

        case v["type"] do
          "bool" ->
            exact!(v, ~w(type initial))
            check!(is_boolean(v["initial"]), "invalid bool")

          "int" ->
            exact!(v, ~w(type initial min max))

            check!(
              Enum.all?([v["min"], v["max"], v["initial"]], &is_integer/1) and
                v["min"] <= v["initial"] and v["initial"] <= v["max"] and
                v["max"] - v["min"] <= 100,
              "invalid int bounds"
            )

          _ ->
            check!(false, "unknown variable type")
        end
      end)

      defs = clues(g)
      check!(is_map(defs) and map_size(defs) in 1..50, "invalid clues")
      check!(byte_size(Jason.encode!(defs)) <= 32_768, "clue projection budget exceeded")

      Enum.each(defs, fn {code, d} ->
        exact!(d, ~w(title text shareable))

        check!(
          code?(code) and text?(d["title"], 120) and text?(d["text"], 2000) and
            is_boolean(d["shareable"]),
          "invalid clue definition"
        )
      end)

      check!(is_list(g["actions"]) and length(g["actions"]) in 1..50, "invalid actions")
      check!(unique?(Enum.map(g["actions"], & &1["id"])), "duplicate action")

      Enum.each(g["actions"], fn a ->
        exact!(a, ~w(id role phase requires effects), ~w(label))
        if a["label"], do: check!(text?(a["label"], 120), "invalid action label")

        check!(
          code?(a["id"]) and a["role"] in g["roles"] and a["phase"] == "exploration",
          "invalid action reference"
        )

        condition!(a["requires"], g, 0)
        check!(is_list(a["effects"]) and length(a["effects"]) in 1..10, "invalid effects")
        Enum.each(a["effects"], &effect!(&1, g))
      end)

      d = g["decision"]
      exact!(d, ~w(duration_ms options eligibility default_option tie_priority endings))

      if g["option_labels"] do
        check!(
          is_map(g["option_labels"]) and
            Enum.all?(g["option_labels"], fn {code, label} ->
              code in d["options"] and text?(label, 120)
            end),
          "invalid option labels"
        )
      end

      check!(
        is_list(d["options"]) and length(d["options"]) in 1..10 and unique?(d["options"]) and
          Enum.all?(d["options"], &code?/1) and d["default_option"] in d["options"] and
          is_list(d["tie_priority"]) and Enum.sort(d["tie_priority"]) == Enum.sort(d["options"]),
        "invalid default or tie order"
      )

      check!(
        is_map(d["eligibility"]) and Enum.all?(Map.keys(d["eligibility"]), &(&1 in d["options"])),
        "invalid eligibility reference"
      )

      Enum.each(d["eligibility"], fn {_, c} -> condition!(c, g, 0) end)

      Enum.each(d["eligibility"], fn {_, c} ->
        check!(public_condition?(c), "decision eligibility must use shared facts")
      end)

      check!(
        d["eligibility"][d["default_option"]] in [nil, %{"all" => []}],
        "default must be unconditional"
      )

      check!(
        is_map(d["endings"]) and Enum.sort(Map.keys(d["endings"])) == Enum.sort(d["options"]) and
          Enum.all?(Map.values(d["endings"]), &code?/1),
        "missing ending"
      )

      empty = %{
        "known" => Map.new(g["roles"], &{&1, []}),
        "shared" => [],
        "items" => %{},
        "vars" => initial_vars(g),
        "done" => []
      }

      check!(
        condition(d["eligibility"][d["default_option"]], empty, hd(g["roles"])),
        "default must be unconditionally available"
      )

      exact!(g["timing"], ~w(exploration_ms interlude_ms ending_ms))

      Enum.each(
        [d["duration_ms"] | Map.values(g["timing"])],
        &check!(is_integer(&1) and &1 in 1000..900_000, "invalid timer")
      )

      check!(is_list(g["media"]) and unique?(g["media"]), "invalid media")

      required =
        ~w(opening interlude) ++
          Enum.map(g["roles"], &("role_" <> &1)) ++
          Enum.map(Enum.uniq(Map.values(d["endings"])), &("ending_" <> &1))

      check!(Enum.sort(g["media"]) == Enum.sort(required), "missing media usage")

      check!(
        is_list(g["assets"]) and length(g["assets"]) == length(required),
        "missing media bindings"
      )

      check!(
        Enum.sort(Enum.map(g["assets"], & &1["media_id"])) == Enum.sort(required) and
          unique?(Enum.map(g["assets"], & &1["asset_id"])),
        "duplicate media binding"
      )

      Enum.each(g["assets"], fn a ->
        exact!(a, ~w(media_id asset_id sha256 duration_ms summary source))

        check!(
          Ruxi.Contract.uuid?(a["asset_id"]) and is_binary(a["sha256"]) and
            Regex.match?(~r/^[0-9a-f]{64}$/, a["sha256"]) and
            is_integer(a["duration_ms"]) and a["duration_ms"] in 1000..900_000 and
            text?(a["summary"], 2000) and text?(a["source"], 2000),
          "invalid asset or rights source"
        )
      end)

      check!(is_integer(limit) and limit in 1..50_000, "invalid exploration budget")

      {complete, count, endings} =
        explore(:queue.from_list([empty]), MapSet.new([key(empty)]), MapSet.new(), g, limit)

      missing = MapSet.difference(MapSet.new(Map.values(d["endings"])), endings) |> Enum.sort()

      %{
        "valid" => complete and missing == [],
        "complete" => complete,
        "errors" =>
          if(!complete,
            do: ["state budget exceeded"],
            else: Enum.map(missing, &("unreachable ending: " <> &1))
          ),
        "states_checked" => count,
        "reachable_endings" => Enum.sort(endings),
        "compiled_hash" => Util.hash(g),
        "min_protocol_version" => g["min_protocol_version"] || 1
      }
    rescue
      _ -> %{"valid" => false, "complete" => true, "errors" => ["malformed content structure"]}
    catch
      {:content_error, message} -> %{"valid" => false, "complete" => true, "errors" => [message]}
    end
  end

  def condition(nil, _, _), do: true
  def condition(%{"all" => xs}, s, r), do: Enum.all?(xs, &condition(&1, s, r))
  def condition(%{"any" => xs}, s, r), do: Enum.any?(xs, &condition(&1, s, r))
  def condition(%{"not" => x}, s, r), do: !condition(x, s, r)
  def condition(%{"public_clue" => c}, s, _), do: c in s["shared"]
  def condition(%{"owns_item" => c}, s, r), do: r != nil and s["items"][c] == r
  def condition(%{"knows_clue" => c}, s, r), do: c in (s["known"][r] || []) or c in s["shared"]
  def condition(%{"var" => v, "eq" => x}, s, _), do: s["vars"][v] == x
  def condition(_, _, _), do: false

  def available?(a, s),
    do:
      a["id"] not in s["done"] and condition(a["requires"], s, a["role"]) and
        Enum.all?(a["effects"], fn e ->
          !e["grant_item"] or !Map.has_key?(s["items"], e["grant_item"])
        end)

  def execute(a, s) do
    s =
      Enum.reduce(a["effects"], s, fn e, state ->
        cond do
          e["set_variable"] ->
            put_in(state, ["vars", e["set_variable"]], e["value"])

          true ->
            c = e["grant_clue"] || e["grant_item"]
            state = update_in(state, ["known", a["role"]], &Enum.sort(Enum.uniq([c | &1])))

            state =
              if e["visibility"] == "public",
                do: Map.update!(state, "shared", &Enum.sort(Enum.uniq([c | &1]))),
                else: state

            if e["grant_item"], do: put_in(state, ["items", c], a["role"]), else: state
        end
      end)

    Map.update!(s, "done", &Enum.sort([a["id"] | &1]))
  end

  defp explore(queue, seen, endings, g, limit) do
    case :queue.out(queue) do
      {:empty, _} ->
        {true, MapSet.size(seen), endings}

      {{:value, s}, rest} ->
        endings =
          Enum.reduce(g["decision"]["options"], endings, fn option, acc ->
            if condition(g["decision"]["eligibility"][option], s, hd(g["roles"])),
              do: MapSet.put(acc, g["decision"]["endings"][option]),
              else: acc
          end)

        actions = g["actions"] |> Enum.filter(&available?(&1, s)) |> Enum.map(&execute(&1, s))

        shares =
          for {_r, known} <- s["known"],
              c <- known,
              clues(g)[c]["shareable"] and c not in s["shared"],
              do: Map.update!(s, "shared", &Enum.sort([c | &1]))

        transfers =
          for {c, owner} <- s["items"],
              r <- g["roles"],
              r != owner,
              do:
                put_in(s, ["items", c], r)
                |> update_in(["known", r], &Enum.sort(Enum.uniq([c | &1])))

        {queue, seen} =
          Enum.reduce(actions ++ shares ++ transfers, {rest, seen}, fn next, {q, acc} ->
            k = key(next)

            if MapSet.member?(acc, k),
              do: {q, acc},
              else: {:queue.in(next, q), MapSet.put(acc, k)}
          end)

        if MapSet.size(seen) > limit,
          do: {false, MapSet.size(seen), endings},
          else: explore(queue, seen, endings, g, limit)
    end
  end

  defp condition!(c, g, depth) do
    check!(is_map(c) and depth < 8, "invalid condition depth")

    case c do
      %{"all" => xs} when map_size(c) == 1 ->
        check!(is_list(xs) and length(xs) <= 10, "invalid all")
        Enum.each(xs, &condition!(&1, g, depth + 1))

      %{"any" => xs} when map_size(c) == 1 ->
        check!(is_list(xs) and length(xs) in 1..10, "invalid any")
        Enum.each(xs, &condition!(&1, g, depth + 1))

      %{"not" => x} when map_size(c) == 1 ->
        condition!(x, g, depth + 1)

      %{"var" => v, "eq" => x} when map_size(c) == 2 ->
        variable_value!(g, v, x)

      _ ->
        check!(
          map_size(c) == 1 and
            Enum.all?(c, fn {op, v} ->
              op in ~w(public_clue owns_item knows_clue) and Map.has_key?(clues(g), v)
            end),
          "unknown condition or clue"
        )
    end
  end

  defp public_condition?(%{"all" => xs}), do: Enum.all?(xs, &public_condition?/1)
  defp public_condition?(%{"any" => xs}), do: Enum.all?(xs, &public_condition?/1)
  defp public_condition?(%{"not" => x}), do: public_condition?(x)
  defp public_condition?(%{"public_clue" => _}), do: true
  defp public_condition?(%{"var" => _, "eq" => _}), do: true
  defp public_condition?(_), do: false

  defp effect!(e, g) do
    case e do
      %{"set_variable" => v, "value" => x} ->
        exact!(e, ~w(set_variable value))
        variable_value!(g, v, x)

      _ ->
        check!(
          is_map(e) and map_size(e) == 2 and e["visibility"] in ~w(actor public) and
            Enum.count(Map.keys(e), &(&1 in ~w(grant_clue grant_item))) == 1 and
            Map.has_key?(clues(g), e["grant_clue"] || e["grant_item"]),
          "unknown effect or visibility"
        )
    end
  end

  defp variable_value!(g, v, x) do
    d = g["variables"][v]

    check!(
      is_map(d) and
        ((d["type"] == "bool" and is_boolean(x)) or
           (d["type"] == "int" and is_integer(x) and x >= d["min"] and x <= d["max"])),
      "variable type or range mismatch"
    )
  end

  defp exact!(m, required, optional \\ []),
    do:
      check!(
        is_map(m) and Enum.all?(required, &Map.has_key?(m, &1)) and
          Enum.all?(Map.keys(m), &(&1 in (required ++ optional))),
        "unknown or missing field"
      )

  defp code?(x), do: is_binary(x) and Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]{0,63}$/, x)
  defp text?(x, n), do: is_binary(x) and String.length(x) in 1..n
  defp unique?(xs), do: length(xs) == length(Enum.uniq(xs))
  defp key(s), do: Util.hash(s)
  defp check!(true, _), do: :ok
  defp check!(_, message), do: throw({:content_error, message})
end
