defmodule Ruxi.SceneVoice.Coordinator do
  @moduledoc "Durable scene voice leases. No media/token travels through the game stream."
  alias Ruxi.{DB, Util, Limiter}
  alias Ruxi.C2.{Communication, Engine}
  alias Ruxi.SceneVoice.VolcRtcGateway, as: Gateway
  defp gateway, do: Application.get_env(:ruxi, :scene_voice_gateway, Gateway)

  def socket_connected(ctx, reference) do
    DB.transaction(fn ->
      {r, m} = Communication.context!(ctx, ctx.room, true)
      old = participation(r, m)

      # A replacement page must not reuse a lease whose old page can still send
      # a late client_state:left. Retire that generation before restoring it.
      if old && old["socket_ref"] && old["socket_ref"] != reference && lease(r, m),
        do: retire_for(r, m)

      DB.query(
        "INSERT INTO c2_voice_participation(room_id,member_id,device_id,control_epoch,socket_ref) VALUES($1,$2,$3,$4,$5) ON CONFLICT(room_id,member_id) DO UPDATE SET socket_ref=$5",
        [r["id"], m["id"], m["device_id"], m["control_epoch"], reference]
      )
    end)
  end

  def socket_disconnected(ctx, reference) do
    DB.transaction(fn ->
      r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [DB.uuid(ctx.room)])

      m =
        DB.one("SELECT * FROM c2_room_members WHERE id=$1 AND room_id=$2", [
          DB.uuid(ctx.member),
          DB.uuid(ctx.room)
        ])

      p = if r && m, do: participation(r, m), else: nil

      if p && p["socket_ref"] == reference do
        retire_for(r, m)

        DB.query(
          "UPDATE c2_voice_participation SET socket_ref=NULL WHERE room_id=$1 AND member_id=$2",
          [r["id"], m["id"]]
        )

        bump(r)
      end
    end)
  end

  def pending(r),
    do:
      DB.one(
        "SELECT * FROM c2_voice_transitions WHERE room_id=$1 AND phase IN ('retiring','blocked','fenced')",
        [r["id"]]
      )

  defp participation(r, m),
    do:
      DB.one("SELECT * FROM c2_voice_participation WHERE room_id=$1 AND member_id=$2", [
        r["id"],
        m["id"]
      ])

  defp active?(p, m),
    do:
      (p != nil and p["socket_ref"] != nil and p["enabled"]) && not p["restricted"] &&
        p["device_id"] == m["device_id"] &&
        p["control_epoch"] == m["control_epoch"]

  defp lease(r, m),
    do:
      DB.one(
        "SELECT l.*,c.generation,c.rtc_room_id,c.status AS channel_status FROM c2_voice_leases l JOIN c2_voice_channels c ON c.id=l.channel_id WHERE l.room_id=$1 AND l.member_id=$2 AND l.state IN ('issued','connected') AND l.expires_at>$3",
        [r["id"], m["id"], DB.time()]
      )

  defp bump(r),
    do:
      DB.one(
        "UPDATE c2_rooms SET voice_revision=voice_revision+1 WHERE id=$1 RETURNING voice_revision",
        [r["id"]]
      )["voice_revision"]

  defp colocated(r, m) do
    own = Communication.actor(r, m)["location"]
    Enum.filter(Communication.members(r), &(own && Communication.actor(r, &1)["location"] == own))
  end

  defp eligible(r, m),
    do:
      Enum.filter(colocated(r, m), fn other ->
        p = participation(r, other)
        active?(p, other) && other["last_seen_at"] > DB.time() - 30_000
      end)

  defp scene_enabled?(r, m) do
    content = r["state"]["content"]

    location =
      Enum.find(content["locations"] || [], &(&1["id"] == Communication.actor(r, m)["location"]))

    get_in(content, ["communication", "voice", "enabled"]) == true && location &&
      get_in(location, ["voice", "mode"]) != "disabled"
  end

  defp reason(r, m, p) do
    cond do
      length(Communication.members(r)) < 2 -> "SINGLE_PLAYER"
      r["status"] == "lobby" -> "LOBBY"
      r["status"] != "active" -> "SUSPENDED"
      p && p["restricted"] -> "RESTRICTED"
      r["voice_disabled"] -> "STORY_DISABLED"
      not scene_enabled?(r, m) -> "STORY_DISABLED"
      pending(r) -> "RETIRING"
      not gateway().configured?() -> "RTC_NOT_CONFIGURED"
      Ruxi.SceneVoice.Budget.exhausted?() && lease(r, m) == nil -> "BUDGET_EXHAUSTED"
      not gateway().ready?() -> "FENCE_NOT_VERIFIED"
      true -> nil
    end
  end

  def state(ctx, id) do
    {r, m} = Communication.context!(ctx, id)
    state_for(r, m)
  end

  def state_for(r, m) do
    p = participation(r, m)
    enabled = active?(p, m)
    why = reason(r, m, p)
    l = lease(r, m)

    status =
      cond do
        why == "RETIRING" -> "switching"
        why == "SUSPENDED" -> "suspended"
        why == "LOBBY" && enabled -> "waiting"
        why -> "unavailable"
        enabled != true -> "off"
        length(eligible(r, m)) < 2 -> "waiting"
        l && l["channel_status"] == "active" && l["state"] == "connected" -> "connected"
        true -> "connecting"
      end

    peers = if why || enabled != true, do: [], else: eligible(r, m)

    %{
      "voice_protocol_version" => 1,
      "voice_revision" => r["voice_revision"],
      "voice_seq" => r["voice_revision"],
      "world_revision" => r["revision"],
      "participation" => if(enabled, do: "on", else: "off"),
      "status" => status,
      "reason" => why,
      "generation" => if(l, do: l["generation"], else: nil),
      "lease_id" => if(l, do: DB.str(l["id"]), else: nil),
      "members" =>
        Enum.map(peers, fn other ->
          ol = lease(r, other)
          user = DB.one("SELECT display_name FROM users WHERE id=$1", [other["user_id"]])

          %{
            "member_id" => DB.str(other["id"]),
            "display_name" => user["display_name"],
            "rtc_uid" => if(ol, do: ol["rtc_uid"], else: nil),
            "mic_state" => "unknown",
            "connection_state" =>
              if(ol && ol["state"] == "connected", do: "connected", else: "waiting")
          }
        end)
    }
  end

  def request(ctx, id, p) do
    result =
      DB.transaction(fn ->
        {r, m} = Communication.context!(ctx, id, true)
        Communication.control!(ctx, m, p)

        Util.require!(
          Enum.sort(Map.keys(p)) ==
            Enum.sort(
              ~w(voice_protocol_version request_id control_epoch expected_revision action body)
            ) && p["voice_protocol_version"] == 1 && Ecto.UUID.cast(p["request_id"]) != :error &&
            is_integer(p["expected_revision"]) && is_map(p["body"]),
          "INPUT_INVALID"
        )

        action = p["action"]
        hash = Util.hash(p)
        fast = action in ~w(heartbeat renew)

        Limiter.check!(
          {:voice, DB.str(m["id"]), fast},
          if(fast, do: 1 / 6, else: 0.5),
          if(fast, do: 10, else: 30)
        )

        old =
          DB.one(
            "SELECT * FROM c2_communication_requests WHERE room_id=$1 AND member_id=$2 AND request_id=$3",
            [r["id"], m["id"], DB.uuid(p["request_id"])]
          )

        if old do
          Util.require!(old["fingerprint"] == hash, "IDEMPOTENCY_CONFLICT")

          if action in ~w(grant renew),
            do: replay_grant!(r, m, old["result"]),
            else: old["result"]
        else
          Util.require!(p["expected_revision"] == r["voice_revision"], "STALE_REVISION")
          response = execute(r, m, p)

          stored =
            if action in ~w(grant renew),
              do: Map.drop(response, ~w(token app_id rtc_room_id rtc_uid provider)),
              else: response

          DB.query("INSERT INTO c2_communication_requests VALUES($1,$2,$3,$4,$5,$6)", [
            r["id"],
            m["id"],
            DB.uuid(p["request_id"]),
            hash,
            stored,
            DB.time()
          ])

          response
        end
      end)

    if match?({:ok, _}, result), do: notify(id)
    result
  end

  defp execute(r, m, %{"action" => "participation", "body" => body} = p) do
    Util.require!(Map.keys(body) == ["enabled"] && is_boolean(body["enabled"]), "INPUT_INVALID")
    old = participation(r, m)
    if not body["enabled"] && active?(old, m), do: retire_for(r, m)
    rev = bump(r)

    DB.query(
      "INSERT INTO c2_voice_participation(room_id,member_id,enabled,revision,device_id,control_epoch) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(room_id,member_id) DO UPDATE SET enabled=$3,revision=$4,device_id=$5,control_epoch=$6",
      [r["id"], m["id"], body["enabled"], rev, m["device_id"], m["control_epoch"]]
    )

    # Adding a third participant retires the old physical generation too.
    if body["enabled"] && not active?(old, m), do: retire_for(r, m)
    receipt(p, rev, nil)
  end

  defp execute(r, m, %{"action" => "grant", "body" => body}) do
    Util.require!(body == %{}, "INPUT_INVALID")
    authorize!(r, m)
    Util.require!(not Ruxi.SceneVoice.Budget.exhausted?(), "VOICE_UNAVAILABLE")

    DB.query(
      "UPDATE c2_voice_leases SET state='expired' WHERE room_id=$1 AND expires_at<=$2 AND state IN ('issued','connected')",
      [r["id"], DB.time()]
    )

    peers = eligible(r, m)
    Util.require!(length(peers) >= 2, "NOT_READY")
    scene = Communication.actor(r, m)["location"]
    roster = Enum.map(peers, &DB.str(&1["id"])) |> Enum.sort()

    channel =
      DB.one(
        "SELECT * FROM c2_voice_channels WHERE room_id=$1 AND scene_id=$2 AND status='active'",
        [r["id"], scene]
      )

    if channel && channel["roster"] != roster do
      retire_channels(r, [channel], nil)
      Util.fail("NOT_READY")
    end

    channel = channel || create_channel(r, scene, roster)
    l = lease(r, m) || create_lease(r, m, channel)
    Util.require!(l["channel_id"] == channel["id"], "LEASE_REVOKED")
    revision = bump(r)
    grant(Map.put(r, "voice_revision", revision), l, channel, l["token_expires_at"])
  end

  defp execute(r, m, %{"action" => action, "body" => body} = p)
       when action in ~w(heartbeat renew client_state) do
    keys = if action == "client_state", do: ~w(lease_id status), else: ["lease_id"]

    Util.require!(
      Enum.sort(Map.keys(body)) == Enum.sort(keys) && Ecto.UUID.cast(body["lease_id"]) != :error,
      "INPUT_INVALID"
    )

    l = lease(r, m)
    Util.require!(l && DB.str(l["id"]) == body["lease_id"], "LEASE_REVOKED")

    if action == "client_state" && body["status"] in ~w(left failed) do
      retire_for(r, m)
      receipt(p, bump(r), nil)
    else
      authorize!(r, m)

      Util.require!(
        l["device_id"] == m["device_id"] && l["control_epoch"] == m["control_epoch"] &&
          l["channel_status"] == "active",
        "LEASE_REVOKED"
      )

      now = DB.time()
      exp = now + 30_000

      DB.query("UPDATE c2_voice_leases SET expires_at=$2,last_seen_at=$3 WHERE id=$1", [
        l["id"],
        exp,
        now
      ])

      case action do
        "heartbeat" ->
          receipt(p, r["voice_revision"], Util.iso(exp))

        "renew" ->
          token_exp = now + 120_000

          DB.query("UPDATE c2_voice_leases SET token_expires_at=$2 WHERE id=$1", [
            l["id"],
            token_exp
          ])

          DB.query(
            "UPDATE c2_voice_channels SET max_token_expires_at=greatest(max_token_expires_at,$2) WHERE id=$1",
            [l["channel_id"], token_exp]
          )

          grant(r, Map.put(l, "expires_at", exp), l, token_exp)

        "client_state" ->
          Util.require!(body["status"] == "connected", "INPUT_INVALID")
          DB.query("UPDATE c2_voice_leases SET state='connected' WHERE id=$1", [l["id"]])

          DB.query(
            "INSERT INTO c2_voice_usage(lease_id,room_id,joined_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",
            [l["id"], r["id"], now]
          )

          receipt(p, bump(r), Util.iso(exp))
      end
    end
  end

  defp execute(_, _, _), do: Util.fail("INPUT_INVALID")

  defp receipt(p, rev, expiry),
    do: %{
      "voice_protocol_version" => 1,
      "request_id" => p["request_id"],
      "accepted" => true,
      "voice_revision" => rev,
      "lease_expires_at" => expiry
    }

  defp authorize!(r, m) do
    p = participation(r, m)
    Util.require!(active?(p, m), "NOT_READY")
    Util.require!(reason(r, m, p) == nil, "VOICE_UNAVAILABLE")
  end

  defp create_channel(r, scene, roster) do
    gen =
      DB.one(
        "SELECT coalesce(max(generation),0)+1 AS n FROM c2_voice_channels WHERE room_id=$1",
        [r["id"]]
      )["n"]

    DB.one(
      "INSERT INTO c2_voice_channels(id,room_id,scene_id,generation,rtc_room_id,status,roster) VALUES($1,$2,$3,$4,$5,'active',$6) RETURNING *",
      [DB.uuid(Util.id()), r["id"], scene, gen, Util.id(), roster]
    )
  end

  defp create_lease(r, m, c) do
    now = DB.time()

    l =
      DB.one(
        "INSERT INTO c2_voice_leases VALUES($1,$2,$3,$4,$5,$6,$7,'issued',$8,$9,$10,$10) RETURNING *",
        [
          DB.uuid(Util.id()),
          r["id"],
          m["id"],
          c["id"],
          m["device_id"],
          m["control_epoch"],
          Util.id(),
          now + 30_000,
          now + 120_000,
          now
        ]
      )

    DB.query(
      "UPDATE c2_voice_channels SET max_token_expires_at=greatest(max_token_expires_at,$2) WHERE id=$1",
      [c["id"], l["token_expires_at"]]
    )

    l
  end

  defp grant(r, l, c, expiry),
    do: %{
      "voice_protocol_version" => 1,
      "lease_id" => DB.str(l["id"]),
      "generation" => c["generation"],
      "provider" => "volcengine",
      "app_id" => gateway().app_id(),
      "rtc_room_id" => c["rtc_room_id"],
      "rtc_uid" => l["rtc_uid"],
      "token" => gateway().token(c["rtc_room_id"], l["rtc_uid"], expiry),
      "token_expires_at" => Util.iso(expiry),
      "lease_expires_at" => Util.iso(l["expires_at"]),
      "voice_revision" => r["voice_revision"],
      "world_revision" => r["revision"]
    }

  defp replay_grant!(r, m, saved) do
    authorize!(r, m)
    l = lease(r, m)

    Util.require!(
      l && DB.str(l["id"]) == saved["lease_id"] &&
        DateTime.compare(
          DateTime.from_iso8601(saved["token_expires_at"]) |> elem(1),
          DateTime.utc_now()
        ) == :gt,
      "LEASE_REVOKED"
    )

    expiry =
      DateTime.from_iso8601(saved["token_expires_at"])
      |> elem(1)
      |> DateTime.to_unix(:millisecond)

    grant(r, l, l, expiry)
  end

  def retire_for(r, m) do
    channels =
      DB.rows(
        "SELECT c.* FROM c2_voice_channels c WHERE c.room_id=$1 AND c.status='active' AND c.scene_id=$2",
        [r["id"], Communication.actor(r, m)["location"] || ""]
      )

    retire_channels(r, channels, nil)
  end

  def before_commit(r, next, epoch, now) do
    channels =
      DB.rows("SELECT * FROM c2_voice_channels WHERE room_id=$1 AND status='active'", [r["id"]])

    changed =
      Enum.filter(channels, fn c ->
        next["status"] != "active" ||
          Enum.any?(Communication.members(r), fn m ->
            a = Communication.actor(r, m)
            b = get_in(next, ["actors", m["role_id"]]) || %{}

            a["location"] != b["location"] &&
              (a["location"] == c["scene_id"] || b["location"] == c["scene_id"])
          end)
      end)

    if changed == [],
      do: :ready,
      else:
        (
          retire_channels(r, changed, %{"state" => next, "epoch" => epoch, "at" => now})
          :deferred
        )
  end

  defp retire_channels(_, [], _), do: :ok

  defp retire_channels(r, channels, plan) do
    ids = Enum.map(channels, & &1["id"])
    DB.query("UPDATE c2_voice_channels SET status='retiring' WHERE id=ANY($1)", [ids])

    DB.query(
      "UPDATE c2_voice_leases SET state='revoking' WHERE channel_id=ANY($1) AND state IN ('issued','connected')",
      [ids]
    )

    if is_nil(pending(r)) do
      DB.query(
        "INSERT INTO c2_voice_transitions(id,room_id,owner_epoch,base_revision,proposed_state,channel_ids,phase,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,'retiring',$7,$7)",
        [
          DB.uuid(Util.id()),
          r["id"],
          if(plan, do: plan["epoch"], else: r["owner_epoch"]),
          r["revision"],
          if(plan, do: plan["state"], else: nil),
          ids,
          DB.time()
        ]
      )
    else
      DB.query(
        "UPDATE c2_voice_transitions SET channel_ids=(SELECT ARRAY(SELECT DISTINCT unnest(channel_ids || $2::uuid[]))) WHERE room_id=$1 AND phase IN ('retiring','blocked')",
        [r["id"], ids]
      )
    end

    bump(r)
  end

  # Network calls deliberately run outside DB transactions. Re-read under the
  # authoritative room lock before committing the prepared deterministic plan.
  def reconcile(id) do
    DB.transaction(fn ->
      r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [DB.uuid(id)])

      budget_due = Ruxi.SceneVoice.Budget.retire_due?()

      for c <-
            DB.rows("SELECT * FROM c2_voice_channels WHERE room_id=$1 AND status='active'", [
              r["id"]
            ]) do
        peers =
          Enum.filter(
            Communication.members(r),
            &(Communication.actor(r, &1)["location"] == c["scene_id"])
          )

        opted =
          Enum.filter(peers, fn m ->
            active?(participation(r, m), m) && m["last_seen_at"] > DB.time() - 30_000
          end)

        roster = Enum.map(opted, &DB.str(&1["id"])) |> Enum.sort()

        expired =
          DB.one(
            "SELECT count(*) AS n FROM c2_voice_leases WHERE channel_id=$1 AND state IN ('issued','connected') AND expires_at<=$2",
            [c["id"], DB.time()]
          )["n"] > 0

        if budget_due || r["status"] != "active" || length(roster) < 2 || roster != c["roster"] ||
             expired,
           do: retire_channels(r, [c], nil)
      end
    end)
  end

  def recover(id) do
    r = DB.one("SELECT * FROM c2_rooms WHERE id=$1", [DB.uuid(id)])
    t = if r, do: pending(r), else: nil

    if t && (t["attempts"] == 0 || t["updated_at"] <= DB.time() - 5000) do
      cs = DB.rows("SELECT * FROM c2_voice_channels WHERE id=ANY($1)", [t["channel_ids"]])

      fenced =
        Enum.all?(cs, fn channel ->
          Code.ensure_loaded!(gateway())

          if function_exported?(gateway(), :expiry_fenced?, 1) &&
               gateway().expiry_fenced?(channel) do
            true
          else
            gateway().retire(channel["rtc_room_id"]) == :fenced
          end
        end)

      DB.transaction(fn ->
        fresh = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [r["id"]])
        current = pending(fresh)

        if current && current["id"] == t["id"] && current["channel_ids"] == t["channel_ids"] &&
             fresh["revision"] == t["base_revision"] &&
             (fresh["owner_id"] in [nil, Application.get_env(:ruxi, :core_instance, "local-core")] ||
                fresh["lease_until"] <= DB.time()) do
          if fenced do
            DB.query("UPDATE c2_voice_channels SET status='closed' WHERE id=ANY($1)", [
              t["channel_ids"]
            ])

            DB.query("UPDATE c2_voice_leases SET state='closed' WHERE channel_id=ANY($1)", [
              t["channel_ids"]
            ])

            DB.query(
              "UPDATE c2_voice_usage SET left_at=$2 WHERE left_at IS NULL AND lease_id IN (SELECT id FROM c2_voice_leases WHERE channel_id=ANY($1))",
              [t["channel_ids"], DB.time()]
            )

            DB.query("UPDATE c2_voice_transitions SET phase='fenced',updated_at=$2 WHERE id=$1", [
              t["id"],
              DB.time()
            ])
          else
            DB.query(
              "UPDATE c2_voice_transitions SET phase=CASE WHEN created_at<$2::bigint-8000 THEN 'blocked' ELSE 'retiring' END,attempts=attempts+1,updated_at=$2 WHERE id=$1",
              [t["id"], DB.time()]
            )
          end
        end
      end)

      notify(id)
    end
  end

  def prepared_next(r, epoch, now) do
    t = pending(r)

    cond do
      t == nil ->
        nil

      t["phase"] != "fenced" ->
        :blocked

      true ->
        Util.require!(t["base_revision"] == r["revision"], "STALE_OWNER")

        DB.query(
          "UPDATE c2_voice_transitions SET phase='committed',owner_epoch=$2,updated_at=$3 WHERE id=$1",
          [t["id"], epoch, now]
        )

        if t["proposed_state"] do
          s = t["proposed_state"]

          if s["status"] == "active",
            do: s |> Engine.suspend(t["created_at"]) |> Engine.resume(now),
            else: s
        else
          if r["state"]["status"] == "active",
            do: r["state"] |> Engine.suspend(t["created_at"]) |> Engine.resume(now),
            else: r["state"]
        end
    end
  end

  def notify(id) do
    for m <- DB.rows("SELECT id FROM c2_room_members WHERE room_id=$1", [DB.uuid(id)]),
        do:
          RuxiWeb.Endpoint.broadcast(
            "room:#{id}:member:#{DB.str(m["id"])}",
            "communication.changed",
            %{}
          )
  end
end
