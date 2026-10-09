defmodule Ruxi.C2.Engine do
  @moduledoc "Pure, versioned C2 rules; the room store commits the returned facts atomically."
  alias Ruxi.C2.Content
  alias Ruxi.Util, as: U

  def initial(story, now, opts \\ []) do
    Content.compile!(story)

    actors =
      Map.new(story["roles"], fn r ->
        {r["id"],
         %{
           "location" => r["location"],
           "ap_remaining" => story["rules"]["ap_per_round"],
           "ap_reserved" => 0,
           "ended" => false,
           "knowledge" => Enum.uniq(r["knowledge"]),
           "known_locations" =>
             Enum.uniq([
               r["location"]
               | Enum.map(Enum.filter(story["locations"], & &1["discovered"]), & &1["id"])
             ]),
           "used" => %{}
         }}
      end)

    ownership =
      Map.new(
        for {role, items} <- story["initial"]["inventory"],
            item <- items,
            do: {item, %{"owner" => role, "version" => 1}}
      )

    s = %{
      "engine_version" => 2,
      "protocol_version" => 2,
      "content" => story,
      "content_hash" => U.hash(story),
      "status" => "active",
      "phase" => "planning",
      "round" => 1,
      "step" => 1,
      "step_id" => U.id(),
      "deadline" => now + story["rules"]["step_timeout_s"] * 1000,
      "remaining_ms" => nil,
      "world" => story["initial"]["world"],
      "actors" => actors,
      "ownership" => ownership,
      "intents" => %{},
      "proposals" => %{},
      "offers" => %{},
      "shared" => [],
      "fired" => [],
      "settlements" => [],
      "receipts" => %{},
      "cues" => [],
      "cue_acks" => %{},
      "barrier" => nil,
      "vote" => nil,
      "ending" => nil,
      "random_key" => Base.encode64(Keyword.get(opts, :random_key, :crypto.strong_rand_bytes(32)))
    }

    s = events(s, "room_start", nil, now)
    m = Enum.find(story["media"], &(&1["id"] == "opening" and &1["audience"] == "public"))
    if m, do: cue(s, m, "all", nil, true, now), else: s
  end

  defp ensure(true, _), do: :ok
  defp ensure(_, code), do: throw({:c2, code})
  defp actor(s, r), do: Map.fetch!(s["actors"], r)
  defp update_actor(s, r, f), do: update_in(s, ["actors", r], f)
  defp active!(s), do: ensure(s["status"] == "active", "ROOM_SUSPENDED")

  defp planning!(s, now) do
    active!(s)

    ensure(
      s["phase"] == "planning" and is_nil(s["barrier"]) and is_nil(s["vote"]) and
        now < s["deadline"],
      "STEP_CLOSED"
    )
  end

  def command(s, role, type, body, id, now) do
    hash = U.hash(%{"actor" => role, "type" => type, "body" => body})

    key = to_string(role) <> ":" <> to_string(id)

    case s["receipts"][key] do
      %{"hash" => ^hash, "result" => result} ->
        {:ok, s, result}

      %{} ->
        {:error, "IDEMPOTENCY_CONFLICT", s}

      nil ->
        try do
          ensure(Map.has_key?(s["actors"], role), "FORBIDDEN")
          {next, result} = dispatch(s, role, type, body, now)
          result = Map.merge(%{"command_id" => id, "status" => "committed"}, result)
          {:ok, put_in(next, ["receipts", key], %{"hash" => hash, "result" => result}), result}
        catch
          {:c2, code} -> {:error, code, if(code == "RULE_LOOP", do: suspend(s, now), else: s)}
        end
    end
  end

  defp dispatch(s, role, "action.submit", body, now) do
    planning!(s, now)
    ensure(body["step_id"] == s["step_id"] and not actor(s, role)["ended"], "STEP_CLOSED")

    ensure(
      Enum.all?(s["cues"], fn c ->
        not (c["blocking"] and c["audience"] == [role] and not acknowledged?(s, role, c["id"]))
      end),
      "READING_REQUIRED"
    )

    a =
      if body["proposal_id"] do
        p = s["proposals"][body["proposal_id"]]

        ensure(
          p != nil and p["actor"] == role and p["status"] == "ready" and p["expires_at"] > now,
          "PROPOSAL_EXPIRED"
        )

        ensure(p["fingerprint"] == fingerprint(s, role), "PROPOSAL_STALE")
        p["action"]
      else
        action!(s, body["action_id"], false)
      end

    ensure(valid?(s, role, a, now), "CONDITION_CHANGED")
    ensure(a["cost"] <= actor(s, role)["ap_remaining"], "AP_INSUFFICIENT")
    ensure(is_nil(body["target_id"]) or body["target_id"] == a["target"], "CONDITION_CHANGED")
    id = U.id()
    i = %{"id" => id, "action" => a, "proposal_id" => body["proposal_id"]}
    s = invalidate_proposal(s, s["intents"][role], "cancelled")

    s =
      s
      |> put_in(["intents", role], i)
      |> update_actor(role, &Map.put(&1, "ap_reserved", a["cost"]))

    s =
      if body["proposal_id"],
        do: put_in(s, ["proposals", body["proposal_id"], "status"], "confirmed"),
        else: s

    {maybe_resolve(s, now), %{"status" => "queued", "intent_id" => id}}
  end

  defp dispatch(s, role, "action.cancel", body, now) do
    planning!(s, now)
    i = s["intents"][role]
    ensure(i && i["id"] == body["intent_id"], "STEP_CLOSED")

    {s
     |> invalidate_proposal(i, "cancelled")
     |> update_in(["intents"], &Map.delete(&1, role))
     |> update_actor(role, &Map.put(&1, "ap_reserved", 0)), %{}}
  end

  defp dispatch(s, role, "round.end", _, now) do
    planning!(s, now)

    s =
      s
      |> invalidate_proposal(s["intents"][role], "cancelled")
      |> update_in(["intents"], &Map.delete(&1, role))
      |> update_actor(
        role,
        &Map.merge(&1, %{"ap_remaining" => 0, "ap_reserved" => 0, "ended" => true})
      )

    {maybe_resolve(s, now), %{}}
  end

  defp dispatch(s, role, "knowledge.share", b, _) do
    active!(s)
    c = Content.index(s["content"], "clues")[b["clue_id"]]
    ensure(c != nil and c["id"] in actor(s, role)["knowledge"] and c["shareable"], "FORBIDDEN")
    audience = b["audience_member_ids"] || Map.keys(s["actors"])

    ensure(
      is_list(audience) and audience != [] and Enum.all?(audience, &Map.has_key?(s["actors"], &1)),
      "FORBIDDEN"
    )

    s =
      Enum.reduce(
        audience,
        s,
        &update_actor(&2, &1, fn a ->
          Map.update!(a, "knowledge", fn xs -> Enum.uniq([c["id"] | xs]) end)
        end)
      )

    s =
      if MapSet.new(audience) == MapSet.new(Map.keys(s["actors"])),
        do: Map.update!(s, "shared", &Enum.uniq([c["id"] | &1])),
        else: s

    {s, %{}}
  end

  defp dispatch(s, role, "item.offer", b, now) do
    active!(s)
    item = s["ownership"][b["item_id"]]
    target = b["target_member_id"]

    ensure(
      item != nil and item["owner"] == role and Map.has_key?(s["actors"], target) and
        target != role,
      "FORBIDDEN"
    )

    ensure(
      actor(s, role)["location"] == actor(s, target)["location"] and
        not reserved?(s, b["item_id"], now),
      "CONDITION_CHANGED"
    )

    id = U.id()

    o = %{
      "id" => id,
      "item_id" => b["item_id"],
      "from" => role,
      "to" => target,
      "version" => item["version"],
      "expires_at" => now + 30_000,
      "status" => "pending"
    }

    {put_in(s, ["offers", id], o), %{"offer_id" => id}}
  end

  defp dispatch(s, role, type, b, now) when type in ~w(item.accept item.reject item.cancel) do
    active!(s)
    o = s["offers"][b["offer_id"]]
    ensure(o && o["status"] == "pending", "CONDITION_CHANGED")

    ensure(
      (type == "item.cancel" and o["from"] == role) or (type != "item.cancel" and o["to"] == role),
      "FORBIDDEN"
    )

    if type == "item.accept" do
      item = s["ownership"][o["item_id"]]

      ensure(
        o["expires_at"] > now and item["owner"] == o["from"] and item["version"] == o["version"] and
          actor(s, o["from"])["location"] == actor(s, role)["location"],
        "CONDITION_CHANGED"
      )

      s =
        put_in(s, ["ownership", o["item_id"]], %{
          "owner" => role,
          "version" => item["version"] + 1
        })

      {put_in(s, ["offers", o["id"], "status"], "accepted"), %{}}
    else
      {put_in(
         s,
         ["offers", o["id"], "status"],
         if(type == "item.reject", do: "rejected", else: "cancelled")
       ), %{}}
    end
  end

  defp dispatch(s, role, "media.complete", b, now) do
    c = Enum.find(s["cues"], &(&1["id"] == b["cue_id"] and role in &1["audience"]))
    ensure(c && b["mode"] in ~w(watched summary), "FORBIDDEN")

    s =
      update_in(
        s,
        ["cue_acks"],
        &Map.update(&1, role, [c["id"]], fn xs -> Enum.uniq([c["id"] | xs]) end)
      )

    s =
      if s["barrier"] &&
           Enum.all?(s["barrier"]["cue_ids"], fn id ->
             Enum.all?(Map.keys(s["actors"]), &acknowledged?(s, &1, id))
           end),
         do:
           Map.merge(s, %{
             "phase" => "planning",
             "barrier" => nil,
             "deadline" => now + (s["remaining_ms"] || 0),
             "remaining_ms" => nil
           }),
         else: s

    {s, %{}}
  end

  defp dispatch(s, role, "vote.cast", b, now) do
    active!(s)
    v = s["vote"]
    ensure(v != nil and v["id"] == b["vote_id"] and now < v["deadline"], "STEP_CLOSED")
    ensure(b["option_id"] in Enum.map(v["options"], & &1["id"]), "CONDITION_CHANGED")
    {put_in(s, ["vote", "ballots", role], b["option_id"]), %{}}
  end

  defp dispatch(_, _, _, _, _), do: throw({:c2, "INVALID_ARGUMENT"})

  def proposal(s, role, mapping, now) do
    try do
      planning!(s, now)
      ensure(Map.has_key?(s["actors"], role), "FORBIDDEN")
      a = action!(s, mapping["mapped_action_id"] || mapping["template_id"], true)

      ensure(
        is_nil(mapping["target_id"]) or mapping["target_id"] == a["target"],
        "CONDITION_CHANGED"
      )

      ensure(
        valid?(s, role, a, now) and a["cost"] <= actor(s, role)["ap_remaining"],
        "CONDITION_CHANGED"
      )

      id = U.id()

      p = %{
        "id" => id,
        "actor" => role,
        "action" => a,
        "status" => "ready",
        "fingerprint" => fingerprint(s, role),
        "expires_at" => now + s["content"]["rules"]["proposal_ttl_s"] * 1000
      }

      s =
        update_in(
          s,
          ["proposals"],
          &Map.new(
            Enum.map(&1, fn {k, old} ->
              {k,
               if(old["actor"] == role and old["status"] == "ready",
                 do: Map.put(old, "status", "cancelled"),
                 else: old
               )}
            end)
          )
        )

      {:ok, put_in(s, ["proposals", id], p),
       %{
         "proposal_id" => id,
         "display_text" => a["label"],
         "cost" => a["cost"],
         "risk_text" => a["risk_text"] || "执行将消耗标示的行动力",
         "expires_at" => p["expires_at"],
         "allowed_now" => true
       }}
    catch
      {:c2, code} -> {:error, code, s}
    end
  end

  def cancel_proposal(s, role, id) do
    p = s["proposals"][id]

    if p && p["actor"] == role && p["status"] == "ready",
      do: {:ok, put_in(s, ["proposals", id, "status"], "cancelled")},
      else: {:error, "FORBIDDEN", s}
  end

  defp fingerprint(s, r),
    do:
      U.hash(%{
        "release" => s["content_hash"],
        "world" => s["world"],
        "actor" => Map.drop(actor(s, r), ["ap_reserved"]),
        "ownership" => s["ownership"],
        "step" => s["step_id"]
      })

  defp invalidate_proposal(s, %{"proposal_id" => id}, status) when not is_nil(id),
    do: put_in(s, ["proposals", id, "status"], status)

  defp invalidate_proposal(s, _, _), do: s

  defp action!(s, "move:" <> id, _) do
    l = Content.index(s["content"], "links")[id]
    ensure(l != nil, "FORBIDDEN")

    %{
      "id" => "move:" <> id,
      "label" => "移动",
      "location" => l["from"],
      "target" => l["to"],
      "cost" => l["cost"],
      "condition" => l["condition"],
      "display_condition" => l["display_condition"],
      "link" => l,
      "effects" => [%{"op" => "move", "value" => l["to"]}],
      "failure" => [],
      "max_uses" => nil,
      "required_participants" => 1
    }
  end

  defp action!(s, id, templates) do
    a =
      Content.index(s["content"], "actions")[id] ||
        if(templates, do: Content.index(s["content"], "templates")[id], else: nil)

    ensure(a != nil, "FORBIDDEN")
    a
  end

  defp valid?(s, r, a, now) do
    member = actor(s, r)
    target = Content.index(s["content"], "objects")[a["target"]]
    located = member["location"] == a["location"]

    known_target =
      if a["link"],
        do: a["target"] in member["known_locations"] and Map.get(a["link"], "discovered", true),
        else: is_nil(a["target"]) or (target && target["location"] == member["location"])

    tag = is_nil(a["required_tag"]) or (target && a["required_tag"] in target["tags"])
    uses = is_nil(a["max_uses"]) or Map.get(member["used"], a["id"], 0) < a["max_uses"]
    grants = Enum.all?(a["effects"], &(&1["op"] != "grant" or is_nil(s["ownership"][&1["ref"]])))

    located and known_target and tag and uses and grants and condition(s, a["condition"], r, now) and
      (is_nil(a["display_condition"]) or condition(s, a["display_condition"], r, now))
  end

  def condition(s, %{"op" => op, "args" => args}, r, now) when op in ~w(all any not) do
    case op do
      "all" -> Enum.all?(args, &condition(s, &1, r, now))
      "any" -> Enum.any?(args, &condition(s, &1, r, now))
      "not" -> not condition(s, hd(args), r, now)
    end
  end

  def condition(s, %{"op" => "has_knowledge", "ref" => ref}, r, _),
    do: ref in actor(s, r)["knowledge"]

  def condition(s, %{"op" => "owns", "ref" => ref}, r, now),
    do:
      s["ownership"][ref] != nil and s["ownership"][ref]["owner"] == r and
        not reserved?(s, ref, now)

  def condition(s, %{"op" => op, "ref" => ref, "value" => v}, r, _) do
    x =
      case ref do
        "world." <> key -> Map.fetch!(s["world"], key)
        "actor.location" -> actor(s, r)["location"]
        "actor.ap" -> actor(s, r)["ap_remaining"]
        "clock.round" -> s["round"]
      end

    case op do
      "eq" -> x === v
      "ne" -> x !== v
      "gte" -> x >= v
      "lte" -> x <= v
    end
  end

  defp reserved?(s, item, now),
    do:
      Enum.any?(s["offers"], fn {_, o} ->
        o["item_id"] == item and o["status"] == "pending" and o["expires_at"] > now and
          actor(s, o["from"])["location"] == actor(s, o["to"])["location"]
      end)

  def resolve(s, now) do
    try do
      ensure(
        s["status"] == "active" and s["phase"] == "planning" and is_nil(s["vote"]) and
          is_nil(s["barrier"]),
        "STEP_CLOSED"
      )

      {:ok, settle(s, now)}
    catch
      {:c2, code} -> {:error, code, if(code == "RULE_LOOP", do: suspend(s, now), else: s)}
    end
  end

  defp maybe_resolve(s, now) do
    if Enum.all?(s["actors"], fn {r, a} ->
         a["ended"] or a["ap_remaining"] == 0 or Map.has_key?(s["intents"], r)
       end), do: settle(s, now), else: s
  end

  defp order(s) do
    roles = Enum.map(s["content"]["roles"], & &1["id"])
    offset = rem(s["round"] + s["step"] - 2, length(roles))
    Enum.drop(roles, offset) ++ Enum.take(roles, offset)
  end

  defp settle(s, now) do
    ensure(not Enum.any?(s["settlements"], &(&1["step_id"] == s["step_id"])), "STEP_CLOSED")
    before = s
    order = order(s)

    {s, results, _} =
      Enum.reduce(order, {s, [], []}, fn r, {state, results, processed} ->
        a = actor(state, r)

        cond do
          r in processed or a["ended"] or a["ap_remaining"] == 0 ->
            {state, results, processed}

          is_nil(state["intents"][r]) ->
            {update_actor(
               state,
               r,
               &Map.merge(&1, %{"ended" => true, "ap_remaining" => 0, "ap_reserved" => 0})
             ), results ++ [%{"actor" => r, "status" => "passed"}], [r | processed]}

          true ->
            action = state["intents"][r]["action"]

            group =
              Enum.filter(order, fn other ->
                i = state["intents"][other]

                i && i["action"]["id"] == action["id"] &&
                  i["action"]["target"] == action["target"] && other not in processed
              end)

            group = if (action["required_participants"] || 1) > 1, do: group, else: [r]

            valid =
              length(group) >= (action["required_participants"] || 1) and
                Enum.all?(
                  group,
                  &(valid?(state, &1, action, now) and
                      actor(state, &1)["ap_remaining"] >= action["cost"])
                )

            if valid do
              subject = Enum.find(Enum.map(s["content"]["roles"], & &1["id"]), &(&1 in group))

              roll =
                if action["threshold"],
                  do: roll(state, state["intents"][subject]["id"]),
                  else: nil

              success = is_nil(roll) or roll <= action["threshold"]

              state =
                Enum.reduce(group, state, fn role, acc ->
                  update_actor(acc, role, fn m ->
                    m
                    |> Map.put("ap_remaining", m["ap_remaining"] - action["cost"])
                    |> Map.put("ap_reserved", 0)
                    |> Map.update!("used", &Map.update(&1, action["id"], 1, fn n -> n + 1 end))
                  end)
                end)

              state =
                state
                |> effects(
                  if(success, do: action["effects"], else: action["failure"]),
                  subject,
                  now
                )
                |> events("action_end", subject, now)

              entries =
                Enum.map(
                  group,
                  &%{
                    "actor" => &1,
                    "action_id" => action["id"],
                    "intent_id" => state["intents"][&1]["id"],
                    "status" => "resolved",
                    "cost" => action["cost"],
                    "success" => success,
                    "roll" => roll
                  }
                )

              {state, results ++ entries, group ++ processed}
            else
              state =
                Enum.reduce(
                  group,
                  state,
                  &update_actor(&2, &1, fn m -> Map.put(m, "ap_reserved", 0) end)
                )

              {state,
               results ++
                 Enum.map(
                   group,
                   &%{
                     "actor" => &1,
                     "action_id" => action["id"],
                     "status" => "invalidated",
                     "intent_id" => state["intents"][&1]["id"],
                     "cost" => 0
                   }
                 ), group ++ processed}
            end
        end
      end)

    s = events(s, "step_end", nil, now)

    record = %{
      "step_id" => before["step_id"],
      "round" => before["round"],
      "step" => before["step"],
      "order" => order,
      "results" => results,
      "intents" => before["intents"],
      "world" => s["world"]
    }

    s = s |> Map.update!("settlements", &(&1 ++ [record])) |> Map.put("intents", %{})
    s = if s["status"] == "active", do: advance(s, now), else: s
    expire_offers(s, now)
  end

  defp roll(s, id) do
    <<v::unsigned-32, _::binary>> =
      :crypto.mac(:hmac, :sha256, Base.decode64!(s["random_key"]), id)

    rem(v, 100) + 1
  end

  defp advance(s, now) do
    ended =
      s["step"] >= s["content"]["rules"]["ap_per_round"] or
        Enum.all?(s["actors"], fn {_, a} -> a["ended"] or a["ap_remaining"] == 0 end)

    s = if ended, do: events(s, "round_end", nil, now), else: s

    if s["status"] != "active" do
      s
    else
      ensure(
        not (ended and s["round"] >= s["content"]["rules"]["round_limit"] and is_nil(s["vote"]) and
               is_nil(s["barrier"])),
        "RULE_LOOP"
      )

      s =
        if ended do
          s
          |> Map.update!("round", &(&1 + 1))
          |> Map.put("step", 1)
          |> Map.update!("actors", fn actors ->
            Map.new(actors, fn {r, a} ->
              {r,
               Map.merge(a, %{
                 "ap_remaining" => s["content"]["rules"]["ap_per_round"],
                 "ap_reserved" => 0,
                 "ended" => false
               })}
            end)
          end)
        else
          Map.update!(s, "step", &(&1 + 1))
        end

      timeout = s["content"]["rules"]["step_timeout_s"] * 1000
      s = Map.merge(s, %{"step_id" => U.id(), "deadline" => now + timeout})
      if s["barrier"] || s["vote"], do: Map.put(s, "remaining_ms", timeout), else: s
    end
  end

  defp effects(s, es, r, now), do: Enum.reduce(es, s, &effect(&2, &1, r, now))

  defp effect(s, %{"op" => "set", "ref" => "world." <> k, "value" => v}, _, _),
    do: put_in(s, ["world", k], v)

  defp effect(s, %{"op" => "move", "value" => loc}, r, _),
    do: update_actor(s, r, &Map.put(&1, "location", loc))

  defp effect(s, %{"op" => op, "ref" => ref, "audience" => audience}, r, _)
       when op in ~w(reveal discover) do
    field = if op == "reveal", do: "knowledge", else: "known_locations"
    roles = if audience == "all", do: Map.keys(s["actors"]), else: [r]

    s =
      Enum.reduce(
        roles,
        s,
        &update_actor(&2, &1, fn a ->
          Map.update!(a, field, fn xs -> Enum.uniq([ref | xs]) end)
        end)
      )

    if op == "reveal" and audience == "all",
      do: Map.update!(s, "shared", &Enum.uniq([ref | &1])),
      else: s
  end

  defp effect(s, %{"op" => "grant", "ref" => item}, r, _),
    do: put_in(s, ["ownership", item], %{"owner" => r, "version" => 1})

  defp effect(s, %{"op" => "end", "value" => ending}, _, now),
    do:
      if(s["ending"],
        do: s,
        else:
          Map.merge(s, %{
            "ending" => ending,
            "status" => "ending",
            "phase" => nil,
            "deadline" => now + 300_000,
            "barrier" => nil,
            "vote" => nil
          })
      )

  defp effect(s, %{"op" => "cue", "ref" => id} = e, r, now),
    do: cue(s, Content.index(s["content"], "media")[id], e["audience"], r, e["blocking"], now)

  defp effect(s, %{"op" => "start_vote", "ref" => id}, _, now) do
    ensure(is_nil(s["vote"]), "RULE_LOOP")
    v = Content.index(s["content"], "votes")[id]
    options = Enum.filter(v["options"], &condition(s, &1["condition"], nil, now))
    ensure(Enum.any?(options, &(&1["id"] == v["default_option"])), "RULE_LOOP")

    Map.merge(s, %{
      "vote" => %{
        "id" => U.id(),
        "definition_id" => id,
        "label" => v["label"],
        "options" => options,
        "ballots" => %{},
        "default" => v["default_option"],
        "deadline" => now + v["duration_s"] * 1000
      },
      "remaining_ms" => max(0, s["deadline"] - now)
    })
  end

  defp events(s, trigger, r, now), do: events(s, trigger, r, now, 0)
  defp events(_, _, _, _, n) when n >= 32, do: throw({:c2, "RULE_LOOP"})

  defp events(s, trigger, r, now, n) do
    {next, count} =
      s["content"]["events"]
      |> Enum.sort_by(&{&1["priority"], &1["id"]})
      |> Enum.reduce({s, 0}, fn e, {acc, count} ->
        if is_nil(acc["ending"]) and e["trigger"] == trigger and e["id"] not in acc["fired"] and
             condition(acc, e["condition"], r, now) do
          acc = if e["once"], do: Map.update!(acc, "fired", &[e["id"] | &1]), else: acc
          {effects(acc, e["effects"], r, now), count + 1}
        else
          {acc, count}
        end
      end)

    if count == 0 or next["ending"], do: next, else: events(next, trigger, r, now, n + 1)
  end

  defp cue(s, m, audience, r, blocking, now) do
    roles = if audience == "all", do: Map.keys(s["actors"]), else: [r]

    ensure(
      m["audience"] == "public" or Enum.all?(roles, &(&1 in m["audience"])),
      "UNSAFE_AUDIENCE"
    )

    c = %{
      "id" => U.id(),
      "media_id" => m["id"],
      "kind" => m["kind"],
      "text" => m["summary"],
      "audience" => roles,
      "blocking" => blocking
    }

    s = Map.update!(s, "cues", &(&1 ++ [c]))

    if blocking and audience == "all" do
      ids = if s["barrier"], do: s["barrier"]["cue_ids"], else: []

      Map.merge(s, %{
        "phase" => "presentation",
        "remaining_ms" => s["remaining_ms"] || max(0, s["deadline"] - now),
        "barrier" => %{"cue_ids" => ids ++ [c["id"]], "deadline" => now + 300_000}
      })
    else
      s
    end
  end

  defp acknowledged?(s, r, id), do: id in (s["cue_acks"][r] || [])

  defp expire_offers(s, now),
    do:
      Map.update!(s, "offers", fn offers ->
        Map.new(offers, fn {id, o} ->
          {id,
           if(
             o["status"] == "pending" and
               (o["expires_at"] <= now or
                  actor(s, o["from"])["location"] != actor(s, o["to"])["location"]),
             do: Map.put(o, "status", "cancelled"),
             else: o
           )}
        end)
      end)

  def suspend(s, now) do
    windows =
      Map.new(~w(barrier vote), fn key ->
        {key, if(s[key], do: max(0, s[key]["deadline"] - now), else: nil)}
      end)

    Map.merge(s, %{
      "status" => "suspended",
      "remaining_ms" => max(0, s["deadline"] - now),
      "suspended_at" => now,
      "suspended_windows" => windows
    })
  end

  def resume(s, now) do
    s =
      Enum.reduce(~w(barrier vote), s, fn key, acc ->
        if acc[key] do
          remaining = get_in(acc, ["suspended_windows", key]) || 0
          remaining = if key == "barrier" and remaining == 0, do: 300_000, else: remaining
          put_in(acc, [key, "deadline"], now + remaining)
        else
          acc
        end
      end)

    Map.merge(s, %{
      "status" => "active",
      "deadline" => now + (s["remaining_ms"] || 0),
      "suspended_at" => nil
    })
  end

  def tick(s, now) do
    s = expire_offers(s, now)

    cond do
      s["status"] == "ending" and now >= s["deadline"] ->
        {:ok, Map.put(s, "status", "finished")}

      (s["status"] == "active" and s["barrier"]) && now >= s["barrier"]["deadline"] ->
        {:ok, suspend(s, now)}

      (s["status"] == "active" and s["vote"]) && now >= s["vote"]["deadline"] ->
        finish_vote(s, now)

      s["status"] == "active" and s["phase"] == "planning" and now >= s["deadline"] ->
        resolve(s, now)

      s["status"] == "suspended" and now >= s["suspended_at"] + 86_400_000 ->
        {:ok, Map.put(s, "status", "abandoned")}

      true ->
        {:ok, s}
    end
  end

  defp finish_vote(s, now) do
    v = s["vote"]
    counts = Enum.frequencies(Map.values(v["ballots"]))
    top = Enum.max(Map.values(counts), fn -> 0 end)
    winners = Enum.filter(v["options"], &(Map.get(counts, &1["id"], 0) == top))

    chosen =
      if top > 0 and length(winners) == 1,
        do: hd(winners),
        else: Enum.find(v["options"], &(&1["id"] == v["default"]))

    try do
      {:ok,
       s
       |> Map.put("vote", nil)
       |> Map.put("deadline", now + (s["remaining_ms"] || 0))
       |> effects(chosen["effects"], nil, now)
       |> events("step_end", nil, now)}
    catch
      {:c2, code} -> {:error, code, suspend(s, now)}
    end
  end

  def project(s, r, now) do
    a = actor(s, r)
    story = s["content"]
    own = Enum.find(story["roles"], &(&1["id"] == r))

    locations =
      Enum.filter(story["locations"], &(&1["id"] in a["known_locations"]))
      |> Enum.map(&Map.take(&1, ~w(id label description)))

    links =
      Enum.filter(story["links"], fn l ->
        Map.get(l, "discovered", true) and l["from"] in a["known_locations"] and
          l["to"] in a["known_locations"] and
          (is_nil(l["display_condition"]) or condition(s, l["display_condition"], r, now))
      end)
      |> Enum.map(fn l ->
        Map.merge(Map.take(l, ~w(id from to cost)), %{
          "allowed_now" => l["from"] == a["location"] and condition(s, l["condition"], r, now)
        })
      end)

    actions =
      Enum.filter(story["actions"], fn x ->
        x["location"] == a["location"] and
          (is_nil(x["display_condition"]) or condition(s, x["display_condition"], r, now))
      end)
      |> Enum.map(fn x ->
        Map.merge(Map.take(x, ~w(id label cost risk_text required_participants)), %{
          "allowed_now" =>
            valid?(s, r, x, now) and x["cost"] <= a["ap_remaining"] - a["ap_reserved"]
        })
      end)

    knowledge =
      Enum.filter(story["clues"], &(&1["id"] in a["knowledge"]))
      |> Enum.map(&Map.take(&1, ~w(id text shareable)))

    team =
      Enum.map(story["roles"], fn other ->
        m = actor(s, other["id"])
        loc = if m["location"] in a["known_locations"], do: m["location"], else: nil

        %{
          "role_id" => other["id"],
          "label" => other["label"],
          "location_id" => loc,
          "ready" =>
            Map.has_key?(s["intents"], other["id"]) or m["ended"] or m["ap_remaining"] == 0
        }
      end)

    inventory =
      Enum.filter(story["objects"], fn item ->
        o = s["ownership"][item["id"]]
        o && o["owner"] == r
      end)
      |> Enum.map(fn item ->
        Map.merge(Map.take(item, ~w(id label tags)), %{
          "version" => s["ownership"][item["id"]]["version"],
          "reserved" => reserved?(s, item["id"], now)
        })
      end)

    vote =
      if s["vote"],
        do:
          Map.take(s["vote"], ~w(id label deadline))
          |> Map.put("options", Enum.map(s["vote"]["options"], &Map.take(&1, ~w(id label))))
          |> Map.put("own_vote", s["vote"]["ballots"][r]),
        else: nil

    ending =
      if s["ending"],
        do: Content.index(story, "media")[s["ending"]] |> Map.take(~w(id summary kind)),
        else: nil

    own_results =
      s["settlements"]
      |> Enum.take(-8)
      |> Enum.flat_map(fn settlement ->
        settlement["results"]
        |> Enum.filter(&(&1["actor"] == r and &1["status"] != "passed"))
        |> Enum.map(fn result ->
          Map.take(result, ~w(intent_id action_id status cost success))
          |> Map.put("step_id", settlement["step_id"])
          |> Map.put("round", settlement["round"])
          |> Map.put("label", get_in(settlement, ["intents", r, "action", "label"]))
        end)
      end)

    %{
      "room" =>
        Map.take(s, ~w(status phase round step step_id))
        |> Map.put("ending", ending)
        |> Map.put(
          "deadline_at",
          if(s["barrier"], do: s["barrier"]["deadline"], else: s["deadline"])
        ),
      "self" =>
        Map.take(a, ~w(location ap_remaining ap_reserved ended))
        |> Map.put("role_id", r)
        |> Map.put("goals", own["goals"] || []),
      "map" => %{"locations" => locations, "links" => links},
      "actions" => actions,
      "knowledge" => knowledge,
      "own_results" => own_results,
      "own_intent" => if(s["intents"][r], do: Map.take(s["intents"][r], ~w(id)), else: nil),
      "inventory" => inventory,
      "offers" => s["offers"] |> Map.values() |> Enum.filter(&(r in [&1["from"], &1["to"]])),
      "team" => team,
      "vote" => vote,
      "narrative_cues" =>
        Enum.filter(s["cues"], &(r in &1["audience"])) |> Enum.map(&Map.drop(&1, ["audience"])),
      "acknowledged_cues" => s["cue_acks"][r] || []
    }
  end
end
