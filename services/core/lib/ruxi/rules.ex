defmodule Ruxi.Rules do
  @moduledoc "C1 deterministic room rules. All timestamps are supplied by the locked database transaction."
  alias Ruxi.Util, as: U

  @roles %{
    "investigator" => {"调查员", "核对车厢记录，寻找异常。"},
    "passenger" => {"乘客", "你收到了一段来自未来的留言。"},
    "conductor" => {"乘务员", "检查设备，确保末班车安全离站。"}
  }
  alias Ruxi.{Content, ContentAST}

  defp anchor(code, now),
    do: %{
      "media_id" => code,
      "media_epoch" => 1,
      "start_at" => U.iso(now + 1500),
      "position_ms" => 0,
      "rate" => 1
    }

  def roles, do: @roles
  def block(s, now), do: suspend(s, now)

  def initial(room, version, host, now, graph \\ nil) do
    %{
      "room_id" => room,
      "content" => graph || Content.demo_graph(),
      "vars" => ContentAST.initial_vars(graph || Content.demo_graph()),
      "done" => [],
      "content_version_id" => version,
      "host" => host,
      "lifecycle" => "lobby",
      "phase_id" => nil,
      "phase" => nil,
      "step" => nil,
      "deadline" => now + 1_800_000,
      "remaining" => nil,
      "timer_generation" => 0,
      "members" => [],
      "shared" => [],
      "items" => %{},
      "offers" => [],
      "round" => nil,
      "votes" => %{},
      "chat" => [],
      "media_acks" => %{},
      "anchor" => nil,
      "media_epochs" => %{},
      "early" => [],
      "resume" => [],
      "pause_request" => nil,
      "manual_pause_used" => false,
      "role_swap" => nil,
      "ending" => nil,
      "suspended_at" => nil
    }
  end

  def add_member(s, id, user, now) do
    m = %{
      "id" => id,
      "user_id" => user,
      "name" => "玩家 #{length(s["members"]) + 1}",
      "role" => nil,
      "ready" => false,
      "online" => false,
      "offline_at" => now,
      "joined_at" => now,
      "left" => false,
      "known" => [],
      "hints" => [],
      "hint_pending" => nil,
      "hint_used" => 0,
      "generation" => 1,
      "device" => nil
    }

    Map.update!(s, "members", &(&1 ++ [m]))
  end

  def member(s, id), do: Enum.find(s["members"], &(&1["id"] == id))

  def update_member(s, id, fun),
    do:
      Map.update!(s, "members", fn ms ->
        Enum.map(ms, fn m -> if m["id"] == id, do: fun.(m), else: m end)
      end)

  def active?(s),
    do: s["lifecycle"] == "running" and s["phase"] == "exploration" and s["step"] == "active"

  defp all_ids(s), do: Enum.map(s["members"], & &1["id"])
  defp all?(s, ids), do: Enum.all?(all_ids(s), &(&1 in ids))
  defp pending?(x), do: is_map(x) and x["status"] == "pending"
  defp host!(s, id), do: U.require!(s["host"] == id, "NOT_ALLOWED")
  defp lobby!(s), do: U.require!(s["lifecycle"] == "lobby", "NOT_ALLOWED")
  defp explore!(s), do: U.require!(active?(s), "NOT_ALLOWED")

  defp phase(s, code, now) do
    s = cancel_pending(s)

    s =
      Map.merge(s, %{
        "phase" => code,
        "phase_id" => U.id(),
        "timer_generation" => s["timer_generation"] + 1,
        "manual_pause_used" => false,
        "media_acks" => %{},
        "hint_reset" => true,
        "resume" => [],
        "offers" => []
      })

    s =
      Map.update!(s, "members", fn ms ->
        Enum.map(ms, &Map.merge(&1, %{"hints" => [], "hint_pending" => nil, "hint_used" => 0}))
      end)

    case code do
      "briefing" ->
        Map.merge(s, %{
          "lifecycle" => "running",
          "deadline" => nil,
          "media_epochs" => %{"opening" => 1},
          "anchor" => anchor("opening", now)
        })

      "exploration" ->
        Map.merge(s, %{
          "step" => "active",
          "deadline" => now + Content.graph(s)["timing"]["exploration_ms"],
          "early" => []
        })

      "decision" ->
        decision = Content.graph(s)["decision"]

        options =
          Enum.filter(
            decision["options"],
            &ContentAST.condition(decision["eligibility"][&1], Content.abstract(s), nil)
          )

        display =
          Enum.map(decision["options"], fn o ->
            %{"option_id" => o, "label" => Content.option_label(s, o), "eligible" => o in options}
            |> then(fn d ->
              if o in options,
                do: d,
                else:
                  Map.merge(d, %{"reason_code" => "EVIDENCE_REQUIRED", "reason_text" => "需公开关键证据"})
            end)
          end)

        Map.merge(s, %{
          "step" => nil,
          "deadline" => now + decision["duration_ms"],
          "round" => %{
            "round_id" => U.id(),
            "electorate" => Enum.filter(s["members"], &(not &1["left"])) |> Enum.map(& &1["id"]),
            "options" =>
              Enum.map(options, &%{"option_id" => &1, "label" => Content.option_label(s, &1)}),
            "tie_priority" => decision["tie_priority"],
            "default_option" => decision["default_option"],
            "display_options" => display,
            "status" => "open"
          },
          "votes" => %{}
        })

      "ending" ->
        Map.merge(s, %{
          "step" => nil,
          "deadline" => now + Content.graph(s)["timing"]["ending_ms"],
          "media_epochs" => %{("ending_" <> s["ending"]) => 1},
          "anchor" => anchor("ending_" <> s["ending"], now)
        })
    end
  end

  def cancel_pending(s) do
    s
    |> Map.put("pause_request", nil)
    |> Map.update!("offers", fn os ->
      Enum.map(os, fn o -> if pending?(o), do: Map.put(o, "status", "cancelled"), else: o end)
    end)
    |> Map.update!("members", fn ms -> Enum.map(ms, &Map.put(&1, "hint_pending", nil)) end)
  end

  defp interlude(s, now),
    do:
      s
      |> cancel_pending()
      |> Map.merge(%{
        "step" => "interlude",
        "deadline" => now + Content.graph(s)["timing"]["interlude_ms"],
        "timer_generation" => s["timer_generation"] + 1,
        "media_epochs" => %{"interlude" => 1},
        "anchor" => anchor("interlude", now),
        "media_acks" => %{}
      })

  defp freeze_anchor(nil, _now), do: nil

  defp freeze_anchor(a, now) do
    start = DateTime.from_iso8601(a["start_at"]) |> elem(1) |> DateTime.to_unix(:millisecond)

    Map.merge(a, %{
      "position_ms" => a["position_ms"] + max(0, now - start),
      "start_at" => U.iso(now),
      "rate" => 0
    })
  end

  defp resume_anchor(nil, _now), do: nil
  defp resume_anchor(a, now), do: Map.merge(a, %{"start_at" => U.iso(now + 1500), "rate" => 1})

  defp pause(s, now),
    do:
      s
      |> cancel_pending()
      |> Map.merge(%{
        "lifecycle" => "paused",
        "remaining" => if(s["deadline"], do: max(0, s["deadline"] - now), else: nil),
        "deadline" => nil,
        "paused_at" => now,
        "anchor" => freeze_anchor(s["anchor"], now),
        "resume" => [],
        "timer_generation" => s["timer_generation"] + 1
      })

  defp suspend(s, now),
    do:
      s
      |> cancel_pending()
      |> Map.merge(%{
        "lifecycle" => "suspended",
        "remaining" =>
          if(s["phase"] == "exploration" and s["step"] == "interlude",
            do: Content.graph(s)["timing"]["interlude_ms"],
            else: s["remaining"] || if(s["deadline"], do: max(0, s["deadline"] - now), else: nil)
          ),
        "deadline" => nil,
        "suspended_at" => now,
        "anchor" => freeze_anchor(s["anchor"], now),
        "resume" => [],
        "timer_generation" => s["timer_generation"] + 1
      })

  defp settle(s, now) do
    opts = Enum.map(s["round"]["options"], & &1["option_id"])
    tally = Map.new(opts, &{&1, Enum.count(Map.values(s["votes"]), fn v -> v == &1 end)})
    decision = Content.graph(s)["decision"]
    priority = s["round"]["tie_priority"] || decision["tie_priority"]

    winner =
      if Enum.sum(Map.values(tally)) == 0,
        do: s["round"]["default_option"] || decision["default_option"],
        else: Enum.max_by(Enum.filter(priority, &(&1 in opts)), &Map.fetch!(tally, &1))

    ending = decision["endings"][winner]

    s =
      Map.merge(s, %{
        "ending" => ending,
        "round" =>
          Map.merge(s["round"], %{
            "status" => "settled",
            "tally" => tally,
            "winner" => winner,
            "deadline_at" => U.iso(s["deadline"])
          })
      })

    phase(s, "ending", now)
  end

  def tick(s, now) do
    s =
      Map.update!(s, "offers", fn os ->
        Enum.map(os, fn o ->
          if pending?(o) and now >= o["expires"], do: Map.put(o, "status", "expired"), else: o
        end)
      end)

    s =
      if pending?(s["role_swap"]) and now >= s["role_swap"]["expires"],
        do: put_in(s, ["role_swap", "status"], "expired"),
        else: s

    s =
      if s["pause_request"] && now >= s["pause_request"]["expires"],
        do: Map.put(s, "pause_request", nil),
        else: s

    s =
      Enum.reduce(s["members"], s, fn m, a ->
        p = m["hint_pending"]

        if p && now >= p["fallback_at"] && a["lifecycle"] == "running" &&
             (active?(a) or a["phase"] == "decision") &&
             (is_nil(a["deadline"]) or now < a["deadline"]) do
          text = hint_text(a, m["id"], p["level"])
          finish_hint(a, m["id"], p["reservation"], text, "template")
        else
          a
        end
      end)

    host = member(s, s["host"])

    s =
      if host && !host["online"] && now - host["offline_at"] >= 30_000 do
        next =
          s["members"]
          |> Enum.filter(&(&1["online"] and !&1["left"]))
          |> Enum.sort_by(&{&1["joined_at"], &1["id"]})
          |> List.first()

        if next, do: Map.merge(s, %{"host" => next["id"], "pause_request" => nil}), else: s
      else
        s
      end

    cond do
      s["lifecycle"] in ["finished", "abandoned"] ->
        s

      (s["phase"] == "ending" and s["deadline"]) && now >= s["deadline"] ->
        Map.merge(s, %{"lifecycle" => "finished", "deadline" => nil})

      s["phase"] == "ending" ->
        s

      s["lifecycle"] == "lobby" and now >= s["deadline"] ->
        Map.merge(s, %{"lifecycle" => "abandoned", "deadline" => nil, "invite" => nil})

      s["lifecycle"] == "paused" and now - s["paused_at"] >= 300_000 ->
        suspend(s, now)

      s["lifecycle"] == "suspended" and now - s["suspended_at"] >= 86_400_000 ->
        Map.merge(s, %{"lifecycle" => "abandoned", "deadline" => nil})

      ((s["lifecycle"] == "running" and s["phase"] == "exploration" and s["deadline"]) &&
         now >= s["deadline"]) and s["step"] == "active" ->
        interlude(s, now)

      (s["lifecycle"] == "running" and s["phase"] == "exploration" and s["deadline"]) &&
          now >= s["deadline"] ->
        suspend(s, now)

      s["lifecycle"] == "running" and s["phase"] == "decision" and now >= s["deadline"] ->
        settle(s, now)

      s["lifecycle"] == "running" and Enum.all?(s["members"], &(!&1["online"])) ->
        suspend(s, now)

      s["lifecycle"] == "running" and
          Enum.any?(s["members"], &(!&1["online"] and now - &1["offline_at"] >= 120_000)) ->
        pause(s, now)

      true ->
        s
    end
  end

  def presence(s, id, online, now) do
    s =
      update_member(
        s,
        id,
        &Map.merge(&1, %{
          "online" => online,
          "offline_at" => if(online, do: now, else: now),
          "left" => false
        })
      )

    s =
      if !online and pending?(s["role_swap"]) and
           id in [s["role_swap"]["from"], s["role_swap"]["to"]],
         do: put_in(s, ["role_swap", "status"], "cancelled"),
         else: s

    tick(s, now)
  end

  def apply(s, id, type, p, now) do
    m = member(s, id)
    U.require!(m != nil and !m["left"], "NOT_MEMBER")

    case type do
      "select_role" ->
        lobby!(s)
        U.require!(p["role_code"] in Content.graph(s)["roles"], "INVALID_ARGUMENT")

        U.require!(
          !Enum.any?(s["members"], &(&1["id"] != id and &1["role"] == p["role_code"])),
          "ROLE_TAKEN"
        )

        s =
          if pending?(s["role_swap"]) and id in [s["role_swap"]["from"], s["role_swap"]["to"]],
            do: put_in(s, ["role_swap", "status"], "cancelled"),
            else: s

        {update_member(s, id, &Map.merge(&1, %{"role" => p["role_code"], "ready" => false})), p,
         "role_selected"}

      "ready" ->
        lobby!(s)
        U.require!(is_boolean(p["ready"]), "INVALID_ARGUMENT")
        U.require!(!p["ready"] or (m["role"] != nil and !pending?(s["role_swap"])), "NOT_ALLOWED")
        {update_member(s, id, &Map.put(&1, "ready", p["ready"])), p, "ready_changed"}

      "start" ->
        lobby!(s)
        host!(s, id)

        U.require!(
          length(s["members"]) == Content.graph(s)["seat_count"] and
            Enum.all?(s["members"], &(&1["online"] and &1["ready"] and !&1["left"])) and
            !pending?(s["role_swap"]),
          "ROOM_NOT_READY"
        )

        n = phase(s |> Map.put("invite", nil) |> Map.put("started_at", now), "briefing", now)
        {n, %{"phase_id" => n["phase_id"]}, "room_started"}

      "request_role_swap" ->
        lobby!(s)
        to = member(s, p["to_member"])

        U.require!(
          to && to["online"] && m["role"] && to["role"] && to["role"] != m["role"] &&
            !pending?(s["role_swap"]),
          "NOT_ALLOWED"
        )

        sw = %{
          "id" => U.id(),
          "from" => id,
          "to" => to["id"],
          "from_role" => m["role"],
          "to_role" => to["role"],
          "status" => "pending",
          "expires" => now + 30_000
        }

        {Map.put(s, "role_swap", sw),
         %{"role_swap_id" => sw["id"], "expires_at" => U.iso(sw["expires"])},
         "collaboration_changed"}

      t when t in ["accept_role_swap", "reject_role_swap", "cancel_role_swap"] ->
        lobby!(s)
        sw = s["role_swap"]
        U.require!(pending?(sw) and sw["id"] == p["role_swap_id"], "TARGET_CHANGED")

        U.require!(
          id == if(t == "cancel_role_swap", do: sw["from"], else: sw["to"]),
          "NOT_ALLOWED"
        )

        status =
          %{
            "accept_role_swap" => "accepted",
            "reject_role_swap" => "rejected",
            "cancel_role_swap" => "cancelled"
          }[t]

        n = put_in(s, ["role_swap", "status"], status)

        n =
          if status == "accepted",
            do:
              n
              |> update_member(
                sw["from"],
                &Map.merge(&1, %{"role" => sw["to_role"], "ready" => false})
              )
              |> update_member(
                sw["to"],
                &Map.merge(&1, %{"role" => sw["from_role"], "ready" => false})
              ),
            else: n

        {n, %{"role_swap_id" => sw["id"], "status" => status},
         if(status == "accepted", do: "role_selected", else: "collaboration_changed")}

      "media_complete" ->
        media_complete(s, id, p, now)

      "investigate" ->
        explore!(s)
        action = Enum.find(Content.actions(s, m["role"]), &(&1["id"] == p["action_id"]))

        U.require!(
          action != nil and ContentAST.available?(action, Content.abstract(s)),
          "NOT_ALLOWED"
        )

        abstract = ContentAST.execute(action, Content.abstract(s))
        n = update_member(s, id, &Map.put(&1, "known", abstract["known"][m["role"]]))

        n =
          Map.merge(n, %{
            "shared" => abstract["shared"],
            "vars" => abstract["vars"],
            "done" => abstract["done"]
          })

        n =
          Enum.reduce(action["effects"], n, fn e, state ->
            if e["grant_item"],
              do: put_in(state, ["items", e["grant_item"]], %{"owner" => id, "version" => 1}),
              else: state
          end)

        {n, %{"action_id" => action["id"]}, "clue_discovered"}

      "share_clue" ->
        explore!(s)
        c = p["clue_id"]

        U.require!(
          c in m["known"] and ContentAST.clues(Content.graph(s))[c]["shareable"],
          "NOT_ALLOWED"
        )

        {Map.update!(s, "shared", &Enum.uniq(&1 ++ [c])), %{"clue_id" => c, "shared" => true},
         "clue_shared"}

      "offer_item" ->
        explore!(s)
        item = s["items"][p["item_id"]]
        to = member(s, p["to_member"])

        U.require!(
          item && item["owner"] == id && to && to["online"] && !to["left"] && to["id"] != id,
          "NOT_ALLOWED"
        )

        U.require!(item["version"] == p["target_version"], "TARGET_CHANGED")

        U.require!(
          !Enum.any?(s["offers"], &(pending?(&1) and &1["item_id"] == p["item_id"])),
          "NOT_ALLOWED"
        )

        o = %{
          "id" => U.id(),
          "item_id" => p["item_id"],
          "from" => id,
          "to" => to["id"],
          "version" => item["version"],
          "status" => "pending",
          "expires" => now + 30_000
        }

        {Map.update!(s, "offers", &(&1 ++ [o])),
         %{"offer_id" => o["id"], "expires_at" => U.iso(o["expires"])}, "transfer_offered"}

      t when t in ["accept_offer", "reject_offer", "cancel_offer"] ->
        explore!(s)
        o = Enum.find(s["offers"], &(&1["id"] == p["offer_id"]))
        U.require!(pending?(o), "TARGET_CHANGED")
        U.require!(id == if(t == "cancel_offer", do: o["from"], else: o["to"]), "NOT_ALLOWED")
        item = s["items"][o["item_id"]]

        U.require!(
          item["owner"] == o["from"] and item["version"] == o["version"],
          "TARGET_CHANGED"
        )

        status =
          %{
            "accept_offer" => "accepted",
            "reject_offer" => "rejected",
            "cancel_offer" => "cancelled"
          }[t]

        n =
          Map.update!(s, "offers", fn os ->
            Enum.map(os, fn x ->
              if x["id"] == o["id"], do: Map.put(x, "status", status), else: x
            end)
          end)

        n =
          if status == "accepted",
            do:
              n
              |> put_in(["items", o["item_id"]], %{
                "owner" => id,
                "version" => item["version"] + 1
              })
              |> update_member(
                id,
                &Map.update!(&1, "known", fn k -> Enum.uniq(k ++ [o["item_id"]]) end)
              ),
            else: n

        {n, %{"offer_id" => o["id"], "status" => status}, "transfer_resolved"}

      "confirm_exploration_end" ->
        explore!(s)
        n = Map.update!(s, "early", &Enum.uniq(&1 ++ [id]))
        n = if all?(n, n["early"]), do: interlude(n, now), else: n
        {n, %{"confirmed" => true}, "collaboration_changed"}

      "vote" ->
        U.require!(s["lifecycle"] == "running" and s["phase"] == "decision", "NOT_ALLOWED")
        U.require!(p["round_id"] == s["round"]["round_id"], "TARGET_CHANGED")

        U.require!(
          is_nil(s["round"]["electorate"]) or id in s["round"]["electorate"],
          "NOT_ALLOWED"
        )

        U.require!(
          Enum.any?(s["round"]["options"], &(&1["option_id"] == p["option_id"])),
          "NOT_ALLOWED"
        )

        {put_in(s, ["votes", id], p["option_id"]), p, "vote_recorded"}

      "request_pause" ->
        host!(s, id)

        U.require!(
          (active?(s) or (s["lifecycle"] == "running" and s["phase"] == "decision")) and
            !s["manual_pause_used"] and s["pause_request"] == nil,
          "NOT_ALLOWED"
        )

        r = %{"id" => U.id(), "by" => id, "confirmed" => [id], "expires" => now + 30_000}

        {Map.put(s, "pause_request", r), %{"pause_request_id" => r["id"]},
         "collaboration_changed"}

      t when t in ["confirm_pause", "cancel_pause"] ->
        r = s["pause_request"]
        U.require!(r && r["id"] == p["pause_request_id"], "TARGET_CHANGED")

        if t == "cancel_pause" do
          U.require!(r["by"] == id, "NOT_ALLOWED")
          {Map.put(s, "pause_request", nil), %{"cancelled" => true}, "collaboration_changed"}
        else
          n = put_in(s, ["pause_request", "confirmed"], Enum.uniq(r["confirmed"] ++ [id]))

          n =
            if all?(n, n["pause_request"]["confirmed"]),
              do: pause(Map.put(n, "manual_pause_used", true), now),
              else: n

          {n, %{"confirmed" => true}, "lifecycle_changed"}
        end

      "resume" ->
        U.require!(
          s["lifecycle"] in ["paused", "suspended"] and s["phase"] != "ending",
          "NOT_ALLOWED"
        )

        U.require!(p["timer_generation"] == s["timer_generation"], "TARGET_CHANGED")
        U.require!(Enum.all?(s["members"], & &1["online"]), "ROOM_NOT_READY")
        n = Map.update!(s, "resume", &Enum.uniq(&1 ++ [id]))

        n =
          if all?(n, n["resume"]),
            do:
              Map.merge(n, %{
                "lifecycle" => "running",
                "deadline" => if(n["remaining"], do: now + n["remaining"], else: nil),
                "remaining" => nil,
                "anchor" => resume_anchor(n["anchor"], now),
                "timer_generation" => n["timer_generation"] + 1,
                "resume" => []
              }),
            else: n

        {n, %{"confirmed" => true}, "lifecycle_changed"}

      "leave_room" ->
        n =
          if s["lifecycle"] == "lobby",
            do:
              update_member(
                s,
                id,
                &Map.merge(&1, %{
                  "role" => nil,
                  "ready" => false,
                  "left" => true,
                  "online" => false
                })
              ),
            else:
              if(s["phase"] == "ending" or s["lifecycle"] in ["finished", "abandoned"],
                do: s,
                else: suspend(s, now)
              )

        {n, %{"left" => true}, "lifecycle_changed"}

      "chat_send" ->
        U.require!(
          s["lifecycle"] in ["running", "paused", "suspended"] and is_binary(p["text"]) and
            String.length(String.trim(p["text"])) in 1..500,
          "NOT_ALLOWED"
        )

        msg = %{
          "message_id" => U.id(),
          "sender_member" => id,
          "text" => Ruxi.Chat.text!(p["text"]),
          "sent_at" => U.iso(now)
        }

        {Map.update!(s, "chat", &Enum.take(&1 ++ [msg], -50)),
         %{"message_id" => msg["message_id"]}, "chat_added"}

      "request_hint" ->
        U.require!(
          (active?(s) or (s["lifecycle"] == "running" and s["phase"] == "decision")) and
            p["hint_level"] in [1, 2] and m["hint_used"] < 2 and m["hint_pending"] == nil,
          "NOT_ALLOWED"
        )

        h = %{
          "job_id" => U.id(),
          "reservation" => U.id(),
          "level" => p["hint_level"],
          "fallback_at" => now + 8_000
        }

        {update_member(s, id, &Map.put(&1, "hint_pending", h)),
         %{"job_id" => h["job_id"], "reservation_id" => h["reservation"]}, "hint_pending"}

      _ ->
        U.fail("INVALID_ARGUMENT")
    end
  end

  defp media_complete(s, id, p, now) do
    U.require!(s["lifecycle"] == "running", "NOT_ALLOWED")
    auth = project(s, id)["media"]["authorized"]

    U.require!(
      p["mode"] in ["video", "summary"] and
        Enum.any?(
          auth,
          &(&1["media_id"] == p["media_id"] and &1["media_epoch"] == p["media_epoch"])
        ),
      "NOT_ALLOWED"
    )

    key = p["media_id"]
    a = Enum.uniq((s["media_acks"][key] || []) ++ [id])
    n = put_in(s, ["media_acks", key], a)

    n =
      cond do
        s["phase"] == "briefing" and key == "opening" and all?(n, a) ->
          put_in(
            n,
            ["media_epochs"],
            Map.merge(n["media_epochs"], Map.new(s["members"], &{"role_" <> &1["role"], 1}))
          )

        s["phase"] == "briefing" and
            Enum.all?(n["members"], &(&1["id"] in (n["media_acks"]["role_" <> &1["role"]] || []))) ->
          phase(n, "exploration", now)

        s["phase"] == "exploration" and s["step"] == "interlude" and all?(n, a) ->
          phase(n, "decision", now)

        s["phase"] == "ending" and all?(n, a) ->
          Map.merge(n, %{"lifecycle" => "finished", "deadline" => nil})

        true ->
          n
      end

    {n, %{"acknowledged" => true}, "media_changed"}
  end

  def hint_text(s, id, level) do
    m = member(s, id)
    configured = get_in(Content.graph(s), ["hints", m["role"], s["phase"]])

    cond do
      is_list(configured) -> Enum.at(configured, level - 1)
      s["phase"] == "decision" -> "只根据已公开的信息讨论方案，按当前规则选择。"
      level == 1 -> "先查看自己的调查点，再与队友讨论你愿意公开的信息。"
      m["role"] == "investigator" -> "检查监控里的名单。公开你的发现，可能帮助队友继续调查。"
      m["role"] == "passenger" -> "检查手机留言。你可以将已持有的道具交付给在线队友。"
      true -> "检查共享线索和你持有的道具，再尝试操作控制柜。"
    end
  end

  def finish_hint(s, id, reservation, text, source) do
    m = member(s, id)
    p = m["hint_pending"]

    if p && p["reservation"] == reservation do
      update_member(s, id, fn m ->
        Map.merge(m, %{
          "hint_pending" => nil,
          "hint_used" => m["hint_used"] + 1,
          "hints" => m["hints"] ++ [%{"hint_id" => U.id(), "text" => text, "source" => source}]
        })
      end)
    else
      s
    end
  end

  def knowledge_hash(s, id),
    do: U.hash(%{"known" => member(s, id)["known"], "shared" => s["shared"]})

  def project(s, id) do
    m = member(s, id)

    clue = fn c ->
      defn = ContentAST.clues(Content.graph(s))[c]

      %{
        "clue_id" => c,
        "title" => defn["title"],
        "text" => defn["text"],
        "shared" => c in s["shared"]
      }
    end

    role =
      if m["role"],
        do:
          (
            defn = Content.role_definitions(s)[m["role"]]

            %{
              "role_code" => m["role"],
              "title" => defn["title"],
              "description" => defn["description"]
            }
          ),
        else: nil

    actions =
      if active?(s) and m["role"] do
        Enum.map(Content.actions(s, m["role"]), fn a ->
          %{
            "action_id" => a["id"],
            "label" => Content.action_label(a),
            "enabled" => ContentAST.available?(a, Content.abstract(s))
          }
        end)
      else
        []
      end

    authorized =
      cond do
        s["phase"] == "briefing" ->
          ["opening"] ++
            if(Map.has_key?(s["media_epochs"], "role_" <> m["role"]),
              do: ["role_" <> m["role"]],
              else: []
            )

        s["phase"] == "exploration" and s["step"] == "interlude" ->
          ["interlude"]

        s["phase"] == "ending" ->
          ["ending_" <> s["ending"]]

        true ->
          []
      end

    media =
      Enum.map(authorized, fn k ->
        %{
          "media_id" => k,
          "asset_id" => Content.asset_id(s, k),
          "kind" => if(String.starts_with?(k, "role_"), do: "own_role", else: "public"),
          "media_epoch" => s["media_epochs"][k]
        }
      end)

    visible_acks =
      Enum.map(authorized, &%{"media_id" => &1, "members" => s["media_acks"][&1] || []})

    swap = s["role_swap"]

    swap =
      if swap,
        do: %{
          "id" => swap["id"],
          "from_member" => swap["from"],
          "to_member" => swap["to"],
          "from_role_code" => swap["from_role"],
          "to_role_code" => swap["to_role"],
          "status" => swap["status"],
          "expires_at" => U.iso(swap["expires"])
        },
        else: nil

    pause = s["pause_request"]

    pause =
      if pause,
        do: %{
          "id" => pause["id"],
          "expires_at" => U.iso(pause["expires"]),
          "confirmed_members" => pause["confirmed"]
        },
        else: nil

    room = %{
      "room_id" => s["room_id"],
      "content_version_id" => s["content_version_id"],
      "story_id" => s["story_id"],
      "seat_count" => Content.graph(s)["seat_count"],
      "lifecycle" => s["lifecycle"],
      "phase_id" => s["phase_id"],
      "phase_code" => s["phase"],
      "deadline_at" => U.iso(s["deadline"]),
      "remaining_ms" => s["remaining"],
      "timer_generation" => s["timer_generation"],
      "host_membership_id" => s["host"],
      "ending_code" => s["ending"]
    }

    room =
      Map.merge(room, %{
        "body_expires_at" =>
          if(s["terminal_at"], do: U.iso(s["terminal_at"] + 7 * 86_400_000), else: nil),
        "recap_expires_at" =>
          if(s["terminal_at"], do: U.iso(s["terminal_at"] + 180 * 86_400_000), else: nil)
      })

    room =
      Map.put(
        room,
        "role_catalog",
        Enum.map(Content.graph(s)["roles"], fn code ->
          defn = Content.role_definitions(s)[code]

          %{
            "role_code" => code,
            "title" => defn["title"],
            "description" => defn["public_description"] || "选择这个角色，与队友一起参与故事。"
          }
        end)
      )

    room =
      if s["phase"] == "exploration", do: Map.put(room, "exploration_step", s["step"]), else: room

    %{
      "room" => room,
      "self" => %{
        "membership_id" => id,
        "control_generation" => m["generation"],
        "role_code" => m["role"]
      },
      "members" =>
        Enum.map(
          s["members"],
          &%{
            "membership_id" => &1["id"],
            "display_name" => &1["name"],
            "role_code" => &1["role"],
            "ready" => &1["ready"],
            "online" => &1["online"],
            "briefing_ready" =>
              if(&1["role"],
                do: &1["id"] in (s["media_acks"]["role_" <> &1["role"]] || []),
                else: false
              )
          }
        ),
      "public_scene" => %{
        "title" => Content.graph(s)["title"],
        "description" => Content.graph(s)["description"] || "23:17。车门即将关闭，一段未来留言打破了车厢的寂静。",
        "shared_clues" => Enum.map(s["shared"], clue),
        "timeline" => s["public_timeline"] || []
      },
      "own_role" => role,
      "own_clues" => Enum.map(m["known"], clue),
      "visible_items" =>
        Enum.flat_map(s["items"], fn {c, i} ->
          if c in m["known"],
            do: [
              %{
                "item_id" => c,
                "title" => ContentAST.clues(Content.graph(s))[c]["title"],
                "owner_membership_id" => i["owner"],
                "version" => i["version"],
                "transferable" => true
              }
            ],
            else: []
        end),
      "offers" =>
        s["offers"]
        |> Enum.filter(&(id in [&1["from"], &1["to"]]))
        |> Enum.map(
          &%{
            "offer_id" => &1["id"],
            "item_id" => &1["item_id"],
            "from_member" => &1["from"],
            "to_member" => &1["to"],
            "status" => &1["status"],
            "expires_at" => U.iso(&1["expires"])
          }
        ),
      "available_actions" => actions,
      "own_vote" =>
        if(s["votes"][id],
          do: %{"round_id" => s["round"]["round_id"], "option_id" => s["votes"][id]},
          else: nil
        ),
      "vote_round" =>
        if(s["round"],
          do:
            Map.put(
              s["round"],
              "deadline_at",
              if(s["round"]["status"] == "settled",
                do: s["round"]["deadline_at"],
                else: U.iso(s["deadline"])
              )
            ),
          else: nil
        ),
      "hints" => %{
        "remaining" => 2 - m["hint_used"] - if(m["hint_pending"], do: 1, else: 0),
        "pending_job_id" => get_in(m, ["hint_pending", "job_id"]),
        "entries" => m["hints"]
      },
      "chat" => s["chat"],
      "media" => %{
        "authorized" => media,
        "public_anchor" =>
          if(Enum.any?(media, &(&1["kind"] == "public")), do: s["anchor"], else: nil)
      },
      "collaboration" => %{
        "media_acks" => visible_acks,
        "early_finish_acks" => s["early"],
        "interlude_acks" => s["media_acks"]["interlude"] || [],
        "resume_acks" => s["resume"],
        "pause_request" => pause,
        "manual_pause_used" => s["manual_pause_used"],
        "role_swap" => swap
      }
    }
  end
end
