defmodule Ruxi.C2.Store do
  alias Ruxi.{DB, Auth, Util}
  alias Ruxi.C2.Engine

  defp room!(id, lock \\ false) do
    room =
      DB.one(
        "SELECT r.*,l.content AS release_content,l.status AS release_status FROM c2_rooms r JOIN c2_releases l ON l.id=r.release_id WHERE r.id=$1" <>
          if(lock, do: " FOR UPDATE OF r", else: ""),
        [DB.uuid(id)]
      )

    Util.require!(room != nil, "RESOURCE_NOT_FOUND")
    room
  end

  def member!(ctx, rid, lock \\ false) do
    Auth.valid!(ctx)

    m =
      DB.one(
        "SELECT * FROM c2_room_members WHERE room_id=$1 AND user_id=$2" <>
          if(lock, do: " FOR UPDATE", else: ""),
        [DB.uuid(rid), DB.uuid(ctx.user)]
      )

    Util.require!(m != nil, "RESOURCE_NOT_FOUND")
    m
  end

  def list_stories(query \\ %{}) do
    q = String.slice(query["q"] || query["query"] || "", 0, 120)
    category = query["category"] || ""

    seats =
      case Integer.parse(query["seats"] || "") do
        {n, ""} -> n
        _ -> 0
      end

    rows =
      DB.rows(
        "SELECT p.id,p.title,p.summary,p.category,p.difficulty,p.current_release_id,p.updated_at,l.content FROM c2_projects p JOIN c2_releases l ON l.id=p.current_release_id WHERE p.archived_at IS NULL AND l.status='published' AND ($1='' OR p.title ILIKE '%'||$1||'%' OR p.summary ILIKE '%'||$1||'%') AND ($2='' OR p.category=$2) ORDER BY p.updated_at DESC LIMIT 100",
        [q, category]
      )

    rows =
      if seats in 2..4,
        do: Enum.filter(rows, &(length(&1["content"]["roles"]) == seats)),
        else: rows

    rows =
      if query["sort"] == "title", do: Enum.sort_by(rows, & &1["title"]), else: rows

    offset =
      case Integer.parse(query["offset"] || "0") do
        {n, ""} when n >= 0 -> min(n, 100)
        _ -> 0
      end

    total = length(rows)
    items = rows |> Enum.drop(offset) |> Enum.take(24) |> Enum.map(&story_view/1)

    %{
      "items" => items,
      "total" => total,
      "next_cursor" => if(offset + 24 < total, do: to_string(offset + 24), else: nil)
    }
  end

  def story(id) do
    p =
      DB.one(
        "SELECT p.id,p.title,p.summary,p.category,p.difficulty,p.current_release_id,l.content FROM c2_projects p JOIN c2_releases l ON l.id=p.current_release_id WHERE p.id=$1 AND p.archived_at IS NULL AND l.status='published'",
        [DB.uuid(id)]
      )

    Util.require!(p != nil, "RESOURCE_NOT_FOUND")
    story_view(p)
  end

  defp story_view(p),
    do:
      Map.take(p, ~w(title summary category difficulty))
      |> Map.merge(%{
        "story_id" => DB.str(p["id"]),
        "release_id" => DB.str(p["current_release_id"]),
        "seat_count" => length(p["content"]["roles"]),
        "schema_version" => 3,
        "protocol_version" => 2,
        "roles" => Enum.map(p["content"]["roles"], &Map.take(&1, ~w(id label))),
        "estimated_minutes" =>
          ceil(
            p["content"]["rules"]["round_limit"] * p["content"]["rules"]["ap_per_round"] *
              p["content"]["rules"]["step_timeout_s"] / 60
          )
      })

  def create(ctx, p) do
    Auth.valid!(ctx)

    release =
      DB.one(
        "SELECT l.*,p.archived_at FROM c2_releases l JOIN c2_projects p ON p.id=l.project_id WHERE l.id=$1 FOR UPDATE OF l",
        [DB.uuid(p["release_id"])]
      )

    Util.require!(
      release != nil and release["status"] == "published" and release["archived_at"] == nil,
      "RESOURCE_NOT_FOUND"
    )

    id = Util.id()
    invite = Auth.invite_code()
    now = DB.time()

    state = %{
      "status" => "lobby",
      "phase" => nil,
      "content" => release["content"],
      "engine_version" => 2,
      "lobby_expires_at" => now + 1_800_000,
      "swap" => nil
    }

    DB.query(
      "INSERT INTO c2_rooms(id,release_id,host_user_id,status,state,invite_hash,invite_cipher,invite_expires_at,updated_at,created_at) VALUES($1,$2,$3,'lobby',$4,$5,$6,$7,$8,$8)",
      [
        DB.uuid(id),
        release["id"],
        DB.uuid(ctx.user),
        state,
        Util.hash(invite),
        Auth.seal(%{"code" => invite}),
        now + 86_400_000,
        now
      ]
    )

    m = insert_member(ctx, id, now)
    emit_all(id, state, state, now)

    %{
      "room_id" => id,
      "member_id" => DB.str(m["id"]),
      "release_id" => DB.str(release["id"]),
      "invite_code" => invite,
      "protocol_version" => 2
    }
  end

  def join(ctx, p) do
    Auth.valid!(ctx)
    now = DB.time()

    r =
      DB.one("SELECT * FROM c2_rooms WHERE invite_hash=$1 FOR UPDATE", [
        Util.hash(String.upcase(String.trim(p["invite_code"] || "")))
      ])

    Util.require!(
      r != nil and r["status"] == "lobby" and r["invite_expires_at"] > now,
      "INVITE_EXPIRED"
    )

    rid = DB.str(r["id"])

    old =
      DB.one("SELECT * FROM c2_room_members WHERE room_id=$1 AND user_id=$2", [
        r["id"],
        DB.uuid(ctx.user)
      ])

    members = members(rid)

    Util.require!(
      old != nil or length(members) < length(r["state"]["content"]["roles"]),
      "ROOM_FULL"
    )

    m = old || insert_member(ctx, rid, now)
    emit_all(rid, r["state"], r["state"], now)
    %{"room_id" => rid, "member_id" => DB.str(m["id"]), "protocol_version" => 2}
  end

  defp insert_member(ctx, id, now) do
    mid = Util.id()

    DB.query(
      "INSERT INTO c2_room_members(id,room_id,user_id,device_id,stream_id,last_seen_at,joined_at) VALUES($1,$2,$3,$4,$5,$6,$6)",
      [DB.uuid(mid), DB.uuid(id), DB.uuid(ctx.user), DB.uuid(ctx.device), DB.uuid(Util.id()), now]
    )

    member!(ctx, id)
  end

  def members(id),
    do:
      DB.rows(
        "SELECT m.*,u.display_name FROM c2_room_members m JOIN users u ON u.id=m.user_id WHERE m.room_id=$1 ORDER BY m.joined_at,m.id",
        [DB.uuid(id)]
      )

  def snapshot(ctx, id) do
    DB.transaction(fn ->
      r = room!(id, true)
      m = member!(ctx, id)
      now = DB.time()
      view = project(r["state"], m, members(id), r, now)

      %{
        "protocol_version" => 2,
        "room_id" => id,
        "member_id" => DB.str(m["id"]),
        "stream_id" => DB.str(m["stream_id"]),
        "view_seq" => m["view_seq"],
        "blocks" => view,
        "server_time" => now,
        "control_epoch" => m["control_epoch"]
      }
    end)
  end

  defp project(state, m, members, room, now) do
    lobby =
      Enum.map(members, fn x ->
        %{
          "member_id" => DB.str(x["id"]),
          "display_name" => x["display_name"],
          "role_id" => x["role_id"],
          "ready" => x["ready"],
          "online" => x["last_seen_at"] > now - 60_000
        }
      end)

    common = %{
      "members" => lobby,
      "host_member_id" =>
        case Enum.find(members, &(&1["user_id"] == room["host_user_id"])) do
          nil -> nil
          x -> DB.str(x["id"])
        end,
      "own_member_id" => DB.str(m["id"]),
      "story_title" => state["content"]["title"],
      "roles" => Enum.map(state["content"]["roles"], &Map.take(&1, ~w(id label)))
    }

    if state["status"] in ~w(lobby abandoned) and is_nil(state["actors"]) do
      common
      |> Map.merge(%{
        "room" => Map.take(state, ~w(status phase)),
        "roles" => Enum.map(state["content"]["roles"], &Map.take(&1, ~w(id label))),
        "invite_code" =>
          if(m["user_id"] == room["host_user_id"] and room["invite_cipher"],
            do: Auth.unseal(room["invite_cipher"])["code"],
            else: nil
          ),
        "seat_count" => length(state["content"]["roles"]),
        "role_swap" => state["swap"]
      })
    else
      view = Engine.project(state, m["role_id"], now)
      mapping = Map.new(members, &{&1["role_id"], DB.str(&1["id"])})

      view =
        Map.update!(view, "team", fn team ->
          Enum.map(team, &Map.put(&1, "member_id", mapping[&1["role_id"]]))
        end)

      view =
        Map.update!(view, "offers", fn offers ->
          Enum.map(offers, fn offer ->
            offer
            |> Map.put("from_member_id", mapping[offer["from"]])
            |> Map.put("to_member_id", mapping[offer["to"]])
          end)
        end)

      common
      |> Map.merge(view)
      |> Map.put(
        "own_intent",
        if(state["intents"][m["role_id"]],
          do: Map.take(state["intents"][m["role_id"]], ~w(id)),
          else: nil
        )
      )
    end
  end

  def command(ctx, id, c) do
    DB.transaction(fn ->
      r = room!(id, true)
      m = member!(ctx, id, true)
      now = DB.time()

      Util.require!(
        is_map(c) and c["protocol_version"] == 2 and Ruxi.Contract.uuid?(c["command_id"]) and
          is_map(c["body"]) and is_binary(c["type"]),
        "INVALID_ARGUMENT"
      )

      Util.require!(
        Ruxi.C2.Schema.validate(c, Ruxi.C2.Schema.load("protocol")) == [],
        "INVALID_ARGUMENT"
      )

      Util.require!(
        m["device_id"] == DB.uuid(ctx.device) and m["control_epoch"] == c["control_epoch"],
        "STALE_CONTROL"
      )

      old =
        DB.one("SELECT * FROM c2_commands WHERE room_id=$1 AND member_id=$2 AND command_id=$3", [
          r["id"],
          m["id"],
          DB.uuid(c["command_id"])
        ])

      if old do
        Util.require!(old["payload_hash"] == Util.hash(c), "IDEMPOTENCY_CONFLICT")
        old["result"]
      else
        owner = fence!(r, now)
        DB.query("UPDATE c2_room_members SET last_seen_at=$2 WHERE id=$1", [m["id"], now])
        state = r["state"]

        {next, result} =
          if state["status"] == "lobby",
            do: lobby_command(ctx, r, m, c, now),
            else: game_command(ctx, r, m, c, now)

        next =
          if state["status"] == "lobby" and next["status"] == "lobby",
            do: Map.put(next, "lobby_expires_at", now + 1_800_000),
            else: next

        save(r, next, owner, now)
        seq = DB.one("SELECT view_seq FROM c2_room_members WHERE id=$1", [m["id"]])["view_seq"]
        result = Map.merge(result, %{"command_id" => c["command_id"], "receipt_seq" => seq})

        DB.query(
          "INSERT INTO c2_commands(room_id,member_id,command_id,payload_hash,result,created_at) VALUES($1,$2,$3,$4,$5,$6)",
          [r["id"], m["id"], DB.uuid(c["command_id"]), Util.hash(c), result, now]
        )

        result
      end
    end)
  end

  defp fence!(r, now) do
    instance = Application.get_env(:ruxi, :core_instance, "local-core")

    Util.require!(
      r["owner_id"] in [nil, instance] or (r["lease_until"] || 0) <= now,
      "OWNER_UNAVAILABLE"
    )

    DB.one(
      "UPDATE c2_rooms SET owner_id=$2,owner_epoch=owner_epoch+1,lease_until=$3 WHERE id=$1 RETURNING owner_epoch",
      [r["id"], instance, now + 30_000]
    )["owner_epoch"]
  end

  defp lobby_command(ctx, r, m, c, now) do
    s = r["state"]
    b = c["body"]
    rid = DB.str(r["id"])
    result = %{"status" => "committed"}

    case c["type"] do
      "role.select" ->
        Util.require!(
          b["role_id"] in Enum.map(s["content"]["roles"], & &1["id"]) and s["swap"] == nil,
          "INVALID_ARGUMENT"
        )

        Util.require!(
          not Enum.any?(members(rid), &(&1["role_id"] == b["role_id"] and &1["id"] != m["id"])),
          "ROLE_TAKEN"
        )

        DB.query("UPDATE c2_room_members SET role_id=$2,ready=false WHERE id=$1", [
          m["id"],
          b["role_id"]
        ])

        {s, result}

      "member.ready" ->
        Util.require!(
          is_boolean(b["ready"]) and m["role_id"] != nil and s["swap"] == nil,
          "NOT_ALLOWED"
        )

        DB.query("UPDATE c2_room_members SET ready=$2 WHERE id=$1", [m["id"], b["ready"]])
        {s, result}

      "room.start" ->
        rows = members(rid)

        Util.require!(
          r["host_user_id"] == DB.uuid(ctx.user) and length(rows) == length(s["content"]["roles"]) and
            Enum.all?(rows, &(&1["ready"] and &1["role_id"] != nil)) and
            r["release_status"] == "published",
          "NOT_ALLOWED"
        )

        DB.query("UPDATE c2_rooms SET invite_hash=NULL,invite_cipher=NULL WHERE id=$1", [r["id"]])
        {Engine.initial(s["content"], now), result}

      "room.invite.rotate" ->
        Util.require!(r["host_user_id"] == DB.uuid(ctx.user), "FORBIDDEN")
        code = Auth.invite_code()

        DB.query(
          "UPDATE c2_rooms SET invite_hash=$2,invite_cipher=$3,invite_expires_at=$4 WHERE id=$1",
          [r["id"], Util.hash(code), Auth.seal(%{"code" => code}), now + 86_400_000]
        )

        {s, Map.put(result, "invite_code", code)}

      "room.close" ->
        Util.require!(r["host_user_id"] == DB.uuid(ctx.user), "FORBIDDEN")
        {Map.put(s, "status", "abandoned"), result}

      "role.swap.request" ->
        target = Enum.find(members(rid), &(DB.str(&1["id"]) == b["target_member_id"]))

        Util.require!(
          target != nil and target["id"] != m["id"] and target["role_id"] != nil and
            m["role_id"] != nil and
            s["swap"] == nil,
          "NOT_ALLOWED"
        )

        swap = %{
          "id" => Util.id(),
          "from" => DB.str(m["id"]),
          "to" => DB.str(target["id"]),
          "expires_at" => now + 30_000
        }

        {Map.put(s, "swap", swap), Map.put(result, "request_id", swap["id"])}

      type when type in ~w(role.swap.accept role.swap.cancel) ->
        swap = s["swap"]

        Util.require!(
          swap != nil and swap["id"] == b["request_id"] and
            DB.str(m["id"]) in [swap["from"], swap["to"]],
          "NOT_ALLOWED"
        )

        if type == "role.swap.accept" do
          Util.require!(swap["to"] == DB.str(m["id"]) and swap["expires_at"] > now, "NOT_ALLOWED")
          from = Enum.find(members(rid), &(DB.str(&1["id"]) == swap["from"]))

          DB.query("UPDATE c2_room_members SET role_id=NULL,ready=false WHERE id=$1", [from["id"]])

          DB.query("UPDATE c2_room_members SET role_id=$2,ready=false WHERE id=$1", [
            m["id"],
            from["role_id"]
          ])

          DB.query("UPDATE c2_room_members SET role_id=$2 WHERE id=$1", [from["id"], m["role_id"]])
        end

        {Map.put(s, "swap", nil), result}

      _ ->
        Util.fail("INVALID_ARGUMENT")
    end
  end

  defp game_command(ctx, r, m, c, now) do
    s = r["state"]
    b = c["body"]
    role = m["role_id"]

    case c["type"] do
      "room.leave" ->
        {if(s["status"] == "active", do: Engine.suspend(s, now), else: s),
         %{"status" => "committed"}}

      "room.resume" ->
        Util.require!(
          s["status"] == "suspended" and r["release_status"] != "blocked",
          "NOT_ALLOWED"
        )

        s = Map.update(s, "resume_votes", [role], &Enum.uniq([role | &1]))
        ready = length(s["resume_votes"]) == length(s["actors"])

        {if(ready, do: s |> Map.put("resume_votes", []) |> Engine.resume(now), else: s),
         %{"status" => "committed"}}

      "pause.request" ->
        Util.require!(
          r["host_user_id"] == DB.uuid(ctx.user) and s["status"] == "active" and
            s["pause_request"] == nil and s["paused_round"] != s["round"],
          "NOT_ALLOWED"
        )

        {Map.put(s, "pause_request", %{
           "id" => Util.id(),
           "votes" => [role],
           "expires_at" => now + 30_000
         }), %{"status" => "committed"}}

      "pause.confirm" ->
        p = s["pause_request"]

        Util.require!(
          p != nil and p["id"] == b["request_id"] and p["expires_at"] > now,
          "NOT_ALLOWED"
        )

        votes = Enum.uniq([role | p["votes"]])
        s = put_in(s, ["pause_request", "votes"], votes)

        s =
          if length(votes) == length(s["actors"]),
            do:
              s
              |> Engine.suspend(now)
              |> Map.put("paused_round", s["round"])
              |> Map.put("pause_request", nil),
            else: s

        {s, %{"status" => "committed"}}

      _ ->
        Util.require!(r["release_status"] != "blocked", "ROOM_SUSPENDED")

        if c["type"] in ~w(action.submit action.cancel round.end),
          do: Util.require!(c["step_id"] == s["step_id"], "STEP_CLOSED")

        b = if c["type"] == "action.submit", do: Map.put(b, "step_id", c["step_id"]), else: b
        mapping = Map.new(members(DB.str(r["id"])), &{DB.str(&1["id"]), &1["role_id"]})

        b =
          if c["type"] == "item.offer",
            do: Map.put(b, "target_member_id", mapping[b["target_member_id"]]),
            else: b

        b =
          if c["type"] == "knowledge.share" and b["audience_member_ids"],
            do: Map.update!(b, "audience_member_ids", &Enum.map(&1, fn id -> mapping[id] end)),
            else: b

        case Engine.command(s, role, c["type"], b, c["command_id"], now) do
          {:ok, next, result} ->
            {next, result}

          {:error, code, next} ->
            {next,
             %{
               "status" => "rejected",
               "error" => %{
                 "code" => code,
                 "safe_message" => "操作未执行，请检查当前场景",
                 "retryable" => false
               }
             }}
        end
    end
  end

  defp save(r, s, epoch, now) do
    updated =
      DB.query(
        "UPDATE c2_rooms SET state=$2,status=$3,revision=revision+1,updated_at=$4 WHERE id=$1 AND owner_epoch=$5 AND lease_until>$4",
        [r["id"], s, s["status"], now, epoch]
      )

    Util.require!(updated.num_rows == 1, "STALE_OWNER")
    rid = DB.str(r["id"])
    rows = members(rid)
    roles = Map.new(rows, &{&1["role_id"], &1["id"]})

    if s["actors"] do
      for {role, a} <- s["actors"] do
        mid = roles[role]

        DB.query(
          "INSERT INTO c2_actor_states(room_id,member_id,location_id,ap_remaining,ap_reserved,ap_budget,ended) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(room_id,member_id) DO UPDATE SET location_id=$3,ap_remaining=$4,ap_reserved=$5,ended=$7",
          [
            r["id"],
            mid,
            a["location"],
            a["ap_remaining"],
            a["ap_reserved"],
            s["content"]["rules"]["ap_per_round"],
            a["ended"]
          ]
        )

        for clue <- a["knowledge"],
            do:
              DB.query("INSERT INTO c2_knowledge VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [
                r["id"],
                mid,
                clue
              ])

        for loc <- a["known_locations"],
            do:
              DB.query("INSERT INTO c2_known_locations VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [
                r["id"],
                mid,
                loc
              ])
      end

      DB.query(
        "UPDATE c2_intents SET status='replaced' WHERE room_id=$1 AND status IN ('queued','locked')",
        [r["id"]]
      )

      for {role, i} <- s["intents"],
          do:
            DB.query(
              "INSERT INTO c2_intents(id,room_id,member_id,step_id,status,cost,payload) VALUES($1,$2,$3,$4,'queued',$5,$6) ON CONFLICT(id) DO UPDATE SET status='queued'",
              [
                DB.uuid(i["id"]),
                r["id"],
                roles[role],
                DB.uuid(s["step_id"]),
                i["action"]["cost"],
                i
              ]
            )

      for record <- s["settlements"], result <- record["results"], result["intent_id"] != nil do
        intent = get_in(record, ["intents", result["actor"]])

        if intent do
          DB.query(
            "INSERT INTO c2_intents(id,room_id,member_id,step_id,status,cost,payload) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(id) DO UPDATE SET status=EXCLUDED.status",
            [
              DB.uuid(result["intent_id"]),
              r["id"],
              roles[result["actor"]],
              DB.uuid(record["step_id"]),
              result["status"],
              intent["action"]["cost"],
              intent
            ]
          )
        end
      end

      for record <- s["settlements"],
          do:
            DB.query(
              "INSERT INTO c2_step_settlements VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",
              [r["id"], DB.uuid(record["step_id"]), record, now]
            )

      for {item, o} <- s["ownership"],
          do:
            DB.query(
              "INSERT INTO c2_ownership VALUES($1,$2,$3,$4) ON CONFLICT(room_id,item_id) DO UPDATE SET member_id=$3,version=$4",
              [r["id"], item, roles[o["owner"]], o["version"]]
            )

      DB.query("UPDATE c2_offers SET status='cancelled' WHERE room_id=$1 AND status='pending'", [
        r["id"]
      ])

      for {_, o} <- s["offers"],
          do:
            DB.query(
              "INSERT INTO c2_offers VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(id) DO UPDATE SET status=$6",
              [
                DB.uuid(o["id"]),
                r["id"],
                o["item_id"],
                roles[o["from"]],
                roles[o["to"]],
                o["status"],
                o["expires_at"],
                o["version"]
              ]
            )

      if s["ending"],
        do:
          DB.query("INSERT INTO c2_endings VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [
            r["id"],
            s["ending"],
            now
          ])
    end

    emit_all(rid, r["state"], s, now)
  end

  defp emit_all(id, old, new, now) do
    r = room!(id)
    rows = members(id)

    for m <- rows do
      before = project(old, m, rows, r, now)
      after_view = project(new, m, rows, r, now)

      if before != after_view or m["view_seq"] == 0 or old["status"] == "lobby" do
        seq =
          DB.one(
            "UPDATE c2_room_members SET view_seq=view_seq+1 WHERE id=$1 RETURNING view_seq",
            [m["id"]]
          )["view_seq"]

        e = %{
          "stream_id" => DB.str(m["stream_id"]),
          "view_seq" => seq,
          "base_view_seq" => seq - 1,
          "blocks" => after_view,
          "narrative_cues" => after_view["narrative_cues"] || []
        }

        DB.query("INSERT INTO c2_view_events VALUES($1,$2,$3,$4,$5,$6,$7)", [
          r["id"],
          m["id"],
          m["stream_id"],
          seq,
          seq - 1,
          e,
          now
        ])

        DB.query(
          "INSERT INTO c2_outbox(room_id,member_id,stream_id,view_seq,created_at) VALUES($1,$2,$3,$4,$5)",
          [r["id"], m["id"], m["stream_id"], seq, now]
        )
      end
    end
  end

  def command_result(ctx, id, command_id) do
    m = member!(ctx, id)

    r =
      DB.one(
        "SELECT result FROM c2_commands WHERE room_id=$1 AND member_id=$2 AND command_id=$3",
        [DB.uuid(id), m["id"], DB.uuid(command_id)]
      )

    if r, do: r["result"], else: %{"status" => "pending", "command_id" => command_id}
  end

  def games(ctx),
    do: %{
      "items" =>
        DB.rows(
          "SELECT r.id,r.status,r.release_id,r.updated_at,p.title,m.id AS member_id,m.role_id FROM c2_rooms r JOIN c2_room_members m ON m.room_id=r.id JOIN c2_releases l ON l.id=r.release_id JOIN c2_projects p ON p.id=l.project_id WHERE m.user_id=$1 ORDER BY r.updated_at DESC LIMIT 100",
          [DB.uuid(ctx.user)]
        )
        |> Enum.map(fn x ->
          x
          |> Map.put("room_id", DB.str(x["id"]))
          |> Map.update!("release_id", &DB.str/1)
          |> Map.update!("member_id", &DB.str/1)
          |> Map.put("lifecycle", if(x["status"] == "active", do: "running", else: x["status"]))
          |> Map.put("updated_at", Util.iso(x["updated_at"]))
          |> Map.put("can_resume", x["status"] != "abandoned")
          |> Map.delete("id")
        end),
      "next_cursor" => nil
    }

  def block_release(id) do
    for r <-
          DB.rows("SELECT * FROM c2_rooms WHERE release_id=$1 AND status='active' FOR UPDATE", [
            DB.uuid(id)
          ]) do
      now = DB.time()
      epoch = fence!(r, now)
      save(r, Engine.suspend(r["state"], now), epoch, now)
    end
  end

  def tick(id) do
    DB.transaction(fn ->
      r = room!(id, true)
      now = DB.time()
      epoch = fence!(r, now)
      s = r["state"]

      next =
        if s["status"] == "lobby" do
          s = if s["swap"] && s["swap"]["expires_at"] <= now, do: Map.put(s, "swap", nil), else: s
          if s["lobby_expires_at"] <= now, do: Map.put(s, "status", "abandoned"), else: s
        else
          {:ok, next} =
            case Engine.tick(s, now) do
              {:ok, x} -> {:ok, x}
              {:error, _, x} -> {:ok, x}
            end

          rows = members(id)

          if next["status"] == "active" and
               Enum.any?(rows, &(&1["last_seen_at"] <= now - 120_000)),
             do: Engine.suspend(next, now),
             else: next
        end

      if next != s, do: save(r, next, epoch, now)
      :ok
    end)
  end

  def ticket(ctx, id, takeover \\ false) do
    DB.transaction(fn ->
      room!(id, true)
      m = member!(ctx, id, true)

      if m["device_id"] != DB.uuid(ctx.device) do
        Util.require!(takeover == true, "TAKEOVER_REQUIRED")

        DB.query(
          "UPDATE c2_room_members SET device_id=$2,control_epoch=control_epoch+1,stream_id=$3,view_seq=0,ack_seq=0 WHERE id=$1",
          [m["id"], DB.uuid(ctx.device), DB.uuid(Util.id())]
        )
      end

      m = member!(ctx, id)
      token = "c2." <> Util.token()
      expiry = DB.time() + 30_000

      DB.query(
        "INSERT INTO c2_socket_tickets(token_hash,room_id,member_id,session_id,device_id,control_epoch,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
        [
          Util.hash(token),
          DB.uuid(id),
          m["id"],
          DB.uuid(ctx.session),
          DB.uuid(ctx.device),
          m["control_epoch"],
          expiry
        ]
      )

      %{
        "socket_ticket" => token,
        "member_id" => DB.str(m["id"]),
        "control_epoch" => m["control_epoch"],
        "expires_at" => expiry
      }
    end)
  end

  def consume_ticket(token) do
    DB.transaction(fn ->
      now = DB.time()

      t =
        DB.one(
          "UPDATE c2_socket_tickets SET consumed=true WHERE token_hash=$1 AND NOT consumed AND expires_at>$2 RETURNING *",
          [Util.hash(token), now]
        )

      Util.require!(t != nil, "UNAUTHORIZED")

      session =
        DB.one("SELECT * FROM sessions WHERE id=$1 AND NOT revoked AND expires_at>$2", [
          t["session_id"],
          now
        ])

      Util.require!(session != nil and session["audience"] == "player", "UNAUTHORIZED")

      ctx = %{
        user: DB.str(session["user_id"]),
        session: DB.str(session["id"]),
        device: DB.str(t["device_id"]),
        expires: session["expires_at"],
        audience: "player",
        room: DB.str(t["room_id"]),
        member: DB.str(t["member_id"]),
        control_epoch: t["control_epoch"],
        c2: true
      }

      socket_valid!(ctx)
      ctx
    end)
  end

  def socket_valid!(ctx) do
    m = member!(ctx, ctx.room)

    Util.require!(
      DB.str(m["id"]) == ctx.member and m["device_id"] == DB.uuid(ctx.device) and
        m["control_epoch"] == ctx.control_epoch,
      "STALE_CONTROL"
    )

    m
  end

  def heartbeat(ctx) do
    DB.transaction(fn ->
      socket_valid!(ctx)

      DB.query("UPDATE c2_room_members SET last_seen_at=$2 WHERE id=$1", [
        DB.uuid(ctx.member),
        DB.time()
      ])

      %{"server_time" => DB.time()}
    end)
  end

  def ack(ctx, p) do
    DB.transaction(fn ->
      m = socket_valid!(ctx)

      Util.require!(
        p["stream_id"] == DB.str(m["stream_id"]) and is_integer(p["view_seq"]) and
          p["view_seq"] >= 0 and p["view_seq"] <= m["view_seq"],
        "INVALID_ARGUMENT"
      )

      DB.query(
        "UPDATE c2_room_members SET ack_seq=greatest(ack_seq,$2),last_seen_at=$3 WHERE id=$1",
        [m["id"], p["view_seq"], DB.time()]
      )

      %{"ack_seq" => max(m["ack_seq"], p["view_seq"])}
    end)
  end

  def drain do
    DB.transaction(fn ->
      rows =
        DB.rows(
          "SELECT o.id,o.room_id,o.member_id,v.view FROM c2_outbox o JOIN c2_view_events v USING(room_id,member_id,stream_id,view_seq) WHERE o.delivered_at IS NULL ORDER BY o.id LIMIT 128 FOR UPDATE OF o SKIP LOCKED"
        )

      for row <- rows do
        topic = "room:#{DB.str(row["room_id"])}:member:#{DB.str(row["member_id"])}"
        RuxiWeb.Endpoint.broadcast(topic, "room.view", row["view"])
        DB.query("UPDATE c2_outbox SET delivered_at=$2 WHERE id=$1", [row["id"], DB.time()])
      end

      length(rows)
    end)
  end

  def favorites(ctx) do
    Auth.valid!(ctx)

    rows =
      DB.rows(
        "SELECT p.id,p.title,p.summary,p.category,p.difficulty,p.current_release_id,l.content FROM c2_favorites f JOIN c2_projects p ON p.id=f.project_id JOIN c2_releases l ON l.id=p.current_release_id WHERE f.user_id=$1 AND p.archived_at IS NULL AND l.status='published' ORDER BY f.created_at DESC",
        [DB.uuid(ctx.user)]
      )

    %{"items" => Enum.map(rows, &story_view/1)}
  end

  def favorite(ctx, id, body) do
    Auth.valid!(ctx)
    story(id)
    Util.require!(is_boolean(body["saved"]), "INVALID_ARGUMENT")

    if body["saved"],
      do:
        DB.query("INSERT INTO c2_favorites VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [
          DB.uuid(ctx.user),
          DB.uuid(id),
          DB.time()
        ]),
      else:
        DB.query("DELETE FROM c2_favorites WHERE user_id=$1 AND project_id=$2", [
          DB.uuid(ctx.user),
          DB.uuid(id)
        ])

    %{"saved" => body["saved"]}
  end
end
