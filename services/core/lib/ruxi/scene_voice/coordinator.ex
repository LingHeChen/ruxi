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

      # Page replacement changes presence, not scene authorization. A fresh
      # lease prevents a delayed old-page left/heartbeat from touching it.
      if old && old["socket_ref"] != reference, do: detach_member(r, m)

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
        detach_member(r, m)

        DB.query(
          "UPDATE c2_voice_participation SET socket_ref=NULL WHERE room_id=$1 AND member_id=$2",
          [r["id"], m["id"]]
        )

        bump(r)
      end
    end)
  end

  # Explicit logout/revocation changes authorization even if its socket already
  # disappeared. Ordinary transport loss must never be confused with this.
  def revoke_identity(user, device \\ nil) do
    if DB.one("SELECT to_regclass('ruxi.c2_voice_participation') IS NOT NULL AS ready")["ready"] do
      members =
        DB.rows(
          "SELECT m.room_id,m.id FROM c2_room_members m JOIN c2_voice_participation p ON p.room_id=m.room_id AND p.member_id=m.id WHERE m.user_id=$1 AND p.enabled ORDER BY m.room_id",
          [
            DB.uuid(user)
          ]
        )

      for item <- members do
        DB.transaction(fn ->
          r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [item["room_id"]])
          m = DB.one("SELECT * FROM c2_room_members WHERE id=$1", [item["id"]])

          if r && m && (device == nil || m["device_id"] == DB.uuid(device)) do
            retire_for(r, m)

            DB.query(
              "UPDATE c2_voice_participation SET enabled=false WHERE room_id=$1 AND member_id=$2",
              [r["id"], m["id"]]
            )

            bump(r)
          end
        end)

        notify(DB.str(item["room_id"]))
      end
    end

    :ok
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

  defp authorized?(p, m),
    do:
      p != nil && p["enabled"] && not p["restricted"] &&
        p["device_id"] == m["device_id"] && p["control_epoch"] == m["control_epoch"]

  defp active?(p, m), do: authorized?(p, m) && p["socket_ref"] != nil

  defp roster(r, m),
    do: Enum.filter(colocated(r, m), &authorized?(participation(r, &1), &1))

  defp detach_member(r, m) do
    now = DB.time()

    DB.query(
      "UPDATE c2_voice_usage SET left_at=$3 WHERE left_at IS NULL AND lease_id IN (SELECT id FROM c2_voice_leases WHERE room_id=$1 AND member_id=$2 AND state IN ('issued','connected'))",
      [r["id"], m["id"], now]
    )

    DB.query(
      "UPDATE c2_voice_leases SET state='detached',expires_at=$3 WHERE room_id=$1 AND member_id=$2 AND state IN ('issued','connected')",
      [r["id"], m["id"], now]
    )
  end

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

  defp reason(r, m, p), do: reason(r, m, p, Communication.members(r), lease(r, m))

  defp reason(r, m, p, members, current_lease) do
    cond do
      length(members) < 2 -> "SINGLE_PLAYER"
      r["status"] == "lobby" -> "LOBBY"
      r["status"] != "active" -> "SUSPENDED"
      p && p["restricted"] -> "RESTRICTED"
      r["voice_disabled"] -> "STORY_DISABLED"
      not scene_enabled?(r, m) -> "STORY_DISABLED"
      pending(r) || member_pending?(r, m) -> "RETIRING"
      not gateway().configured?() -> "RTC_NOT_CONFIGURED"
      Ruxi.SceneVoice.Budget.exhausted?() && current_lease == nil -> "BUDGET_EXHAUSTED"
      not gateway().ready?() -> "FENCE_NOT_VERIFIED"
      true -> nil
    end
  end

  def state(ctx, id) do
    {r, m} = Communication.context!(ctx, id)
    state_for(r, m)
  end

  def state_for(r, m) do
    # One room-scoped read instead of repeated HTTP SQL per participant.
    members =
      DB.rows(
        """
        SELECT m.*,u.display_name,to_jsonb(p) AS participation,to_jsonb(l) AS voice_lease
        FROM c2_room_members m JOIN users u ON u.id=m.user_id
        LEFT JOIN c2_voice_participation p ON p.room_id=m.room_id AND p.member_id=m.id
        LEFT JOIN LATERAL (
          SELECT l.*,c.generation,c.rtc_room_id,c.status AS channel_status
          FROM c2_voice_leases l JOIN c2_voice_channels c ON c.id=l.channel_id
          WHERE l.room_id=m.room_id AND l.member_id=m.id
            AND l.state IN ('issued','connected') AND l.expires_at>$2
          ORDER BY l.expires_at DESC,l.id LIMIT 1
        ) l ON true WHERE m.room_id=$1 ORDER BY m.id
        """,
        [r["id"], DB.time()]
      )

    members =
      Enum.map(members, fn member ->
        case member["participation"] do
          nil -> member
          p -> Map.put(member, "participation", Map.update!(p, "device_id", &DB.uuid/1))
        end
      end)

    own = Enum.find(members, &(&1["id"] == m["id"])) || %{}
    p = own["participation"]
    enabled = active?(p, m)
    l = own["voice_lease"]
    why = reason(r, m, p, members, l)
    location = Communication.actor(r, m)["location"]

    eligible =
      Enum.filter(members, fn other ->
        location && Communication.actor(r, other)["location"] == location &&
          active?(other["participation"], other) && other["last_seen_at"] > DB.time() - 30_000
      end)

    status =
      cond do
        why == "RETIRING" -> "switching"
        why == "SUSPENDED" -> "suspended"
        why == "LOBBY" && enabled -> "waiting"
        why -> "unavailable"
        enabled != true -> "off"
        l && l["channel_status"] == "active" && l["state"] == "connected" -> "connected"
        length(eligible) < 2 -> "waiting"
        true -> "connecting"
      end

    peers = if why || enabled != true, do: [], else: eligible

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
          ol = other["voice_lease"]

          %{
            "member_id" => DB.str(other["id"]),
            "display_name" => other["display_name"],
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

    if match?({:ok, _}, result) and p["action"] not in ~w(heartbeat renew), do: notify(id)
    result
  end

  defp execute(r, m, %{"action" => "participation", "body" => body} = p) do
    Util.require!(Map.keys(body) == ["enabled"] && is_boolean(body["enabled"]), "INPUT_INVALID")
    old = participation(r, m)
    if not body["enabled"] && authorized?(old, m), do: retire_for(r, m)
    rev = bump(r)

    DB.query(
      "INSERT INTO c2_voice_participation(room_id,member_id,enabled,revision,device_id,control_epoch) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(room_id,member_id) DO UPDATE SET enabled=$3,revision=$4,device_id=$5,control_epoch=$6",
      [r["id"], m["id"], body["enabled"], rev, m["device_id"], m["control_epoch"]]
    )

    # New consent is admitted to the existing scene; revoked UIDs are never reused.
    receipt(p, rev, nil)
  end

  defp execute(r, m, %{"action" => "grant", "body" => body}) do
    Util.require!(body == %{}, "INPUT_INVALID")
    authorize!(r, m)
    Util.require!(not Ruxi.SceneVoice.Budget.exhausted?(), "VOICE_UNAVAILABLE")

    peers = eligible(r, m)
    scene = Communication.actor(r, m)["location"]
    roster = Enum.map(roster(r, m), &DB.str(&1["id"])) |> Enum.sort()

    channel =
      DB.one(
        "SELECT * FROM c2_voice_channels WHERE room_id=$1 AND scene_id=$2 AND status='active'",
        [r["id"], scene]
      )

    Util.require!(channel != nil || length(peers) >= 2, "NOT_READY")

    if channel && channel["roster"] != roster do
      DB.query("UPDATE c2_voice_channels SET roster=$2 WHERE id=$1", [
        channel["id"],
        DB.json(roster)
      ])
    end

    channel = channel || create_channel(r, scene, roster)
    detach_member(r, m)
    l = create_lease(r, m, channel)
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
      detach_member(r, m)
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
      [DB.uuid(Util.id()), r["id"], scene, gen, Util.id(), DB.json(roster)]
    )
  end

  defp create_lease(r, m, c) do
    now = DB.time()

    prior =
      DB.one(
        "SELECT rtc_uid FROM c2_voice_leases WHERE channel_id=$1 AND member_id=$2 AND state IN ('issued','connected','detached') ORDER BY created_at DESC LIMIT 1",
        [c["id"], m["id"]]
      )

    uid =
      if prior,
        do: prior["rtc_uid"],
        else: Util.id() |> String.replace("-", "")

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
          uid,
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

  def member_pending?(r, m),
    do:
      DB.one(
        "SELECT id FROM c2_voice_revocations WHERE room_id=$1 AND member_id=$2 AND phase='pending' LIMIT 1",
        [r["id"], m["id"]]
      ) != nil

  # Persist revocation of every still-valid UID, including detached old pages.
  # This does not retire the shared scene channel or pause other players.
  def retire_for(r, m) do
    jobs =
      DB.checked_query(
        """
        INSERT INTO c2_voice_revocations(id,room_id,member_id,channel_id,rtc_uid,token_expires_at,created_at)
        SELECT md5($4 || channel_id::text || rtc_uid)::uuid,room_id,member_id,channel_id,rtc_uid,max(token_expires_at),$3
        FROM c2_voice_leases WHERE room_id=$1 AND member_id=$2 AND token_expires_at+30000>$3
          AND state NOT IN ('closed','revoked') GROUP BY room_id,member_id,channel_id,rtc_uid
        ON CONFLICT(channel_id,rtc_uid) DO UPDATE SET token_expires_at=greatest(c2_voice_revocations.token_expires_at,excluded.token_expires_at)
        """,
        [r["id"], m["id"], DB.time(), Util.id()]
      )

    detach_member(r, m)

    DB.query(
      "UPDATE c2_voice_leases SET state='revoked' WHERE room_id=$1 AND member_id=$2 AND state NOT IN ('closed','revoked')",
      [r["id"], m["id"]]
    )

    bump(r)
    if jobs.num_rows > 0, do: Ruxi.SceneVoice.Maintenance.wake()
  end

  def recover_members(id) do
    jobs =
      DB.rows(
        "SELECT v.*, c.rtc_room_id FROM c2_voice_revocations v JOIN c2_voice_channels c ON c.id=v.channel_id WHERE v.room_id=$1 AND v.phase='pending'",
        [DB.uuid(id)]
      )

    for job <- jobs do
      Code.ensure_loaded!(gateway())

      expired =
        function_exported?(gateway(), :expiry_fenced?, 1) &&
          gateway().expiry_fenced?(%{"max_token_expires_at" => job["token_expires_at"]})

      result =
        cond do
          expired ->
            :fenced

          function_exported?(gateway(), :revoke, 3) ->
            gateway().revoke(job["rtc_room_id"], job["rtc_uid"], job["accepted_at"])

          true ->
            :unknown
        end

      case result do
        :fenced ->
          DB.query("UPDATE c2_voice_revocations SET phase='fenced' WHERE id=$1", [job["id"]])

        :accepted ->
          DB.query(
            "UPDATE c2_voice_revocations SET accepted_at=coalesce(accepted_at,$2) WHERE id=$1",
            [job["id"], DB.time()]
          )

        _ ->
          :ok
      end
    end

    if jobs != [], do: notify(id)
  end

  def before_commit(r, next, epoch, now) do
    channels =
      DB.rows("SELECT * FROM c2_voice_channels WHERE room_id=$1 AND status='active'", [r["id"]])

    if next["status"] != "active" do
      if channels == [],
        do: :ready,
        else:
          (
            retire_channels(r, channels, %{"state" => next, "epoch" => epoch, "at" => now})
            :deferred
          )
    else
      # Scene movement is a member handoff, not destruction of a shared room.
      # Commit gameplay immediately. Only the moving member's next RTC grant
      # waits for provider-confirmed revocation of its old UID.
      for m <- Communication.members(r) do
        old = Communication.actor(r, m)["location"]
        new = get_in(next, ["actors", m["role_id"], "location"])
        if old != new, do: retire_for(r, m)
      end

      :ready
    end
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

        opted = Enum.filter(peers, &authorized?(participation(r, &1), &1))
        roster = Enum.map(opted, &DB.str(&1["id"])) |> Enum.sort()

        # Expiring a presence lease must not revoke unchanged scene permission
        # for every peer. Member revocations fence their UIDs; scene changes
        # fence the physical generation before world commit.
        for m <- peers do
          l =
            DB.one(
              "SELECT id FROM c2_voice_leases WHERE room_id=$1 AND member_id=$2 AND state IN ('issued','connected') AND expires_at<=$3",
              [r["id"], m["id"], DB.time()]
            )

          if l, do: detach_member(r, m)
        end

        if budget_due || r["status"] != "active" do
          retire_channels(r, [c], nil)
        else
          if roster != c["roster"],
            do:
              DB.query("UPDATE c2_voice_channels SET roster=$2 WHERE id=$1", [
                c["id"],
                DB.json(roster)
              ])

          Code.ensure_loaded!(gateway())

          occupied =
            DB.one(
              "SELECT count(*) AS n FROM c2_voice_leases WHERE channel_id=$1 AND state IN ('issued','connected') AND expires_at>$2",
              [c["id"], DB.time()]
            )["n"] > 0

          if not occupied && function_exported?(gateway(), :expiry_fenced?, 1) &&
               gateway().expiry_fenced?(c) do
            DB.query("UPDATE c2_voice_channels SET status='closed' WHERE id=$1", [c["id"]])
            DB.query("UPDATE c2_voice_leases SET state='closed' WHERE channel_id=$1", [c["id"]])
            bump(r)
          end
        end
      end
    end)
  end

  def recover(id) do
    recover_members(id)
    r = DB.one("SELECT * FROM c2_rooms WHERE id=$1", [DB.uuid(id)])
    t = if r, do: pending(r), else: nil

    if t && (t["attempts"] == 0 || t["updated_at"] <= DB.time() - 1000) do
      cs = DB.rows("SELECT * FROM c2_voice_channels WHERE id=ANY($1)", [t["channel_ids"]])

      fenced =
        Enum.map(cs, fn channel ->
          Code.ensure_loaded!(gateway())

          if function_exported?(gateway(), :expiry_fenced?, 1) &&
               gateway().expiry_fenced?(channel) do
            true
          else
            result =
              if function_exported?(gateway(), :revoke, 3),
                do: gateway().revoke(channel["rtc_room_id"], nil, channel["ban_accepted_at"]),
                else: gateway().retire(channel["rtc_room_id"])

            if result == :accepted,
              do:
                DB.query(
                  "UPDATE c2_voice_channels SET ban_accepted_at=coalesce(ban_accepted_at,$2) WHERE id=$1",
                  [channel["id"], DB.time()]
                )

            result == :fenced
          end
        end)
        |> Enum.all?()

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

  def notify(id, kind \\ :voice) do
    for m <- DB.rows("SELECT id FROM c2_room_members WHERE room_id=$1", [DB.uuid(id)]),
        do:
          Ruxi.DB.broadcast(
            "room:#{id}:member:#{DB.str(m["id"])}",
            "communication.changed",
            %{kind: kind}
          )
  end
end
