defmodule Ruxi.Store do
  alias Ruxi.{DB, Util, Rules, Contract, Auth}

  def load!(rid, lock \\ false) do
    row =
      DB.one("SELECT * FROM rooms WHERE id=$1" <> if(lock, do: " FOR UPDATE", else: ""), [
        DB.uuid(rid)
      ])

    Util.require!(row != nil, "RESOURCE_NOT_FOUND")
    row
  end

  def auth!(s, ctx) do
    m = Rules.member(s, ctx.member)
    Util.require!(m != nil and m["user_id"] == ctx.user, "RESOURCE_NOT_FOUND")

    Util.require!(
      m["generation"] == ctx.generation and m["device"] == ctx.device,
      "CONTROL_REPLACED"
    )
  end

  def save(old, new, type, now) do
    new =
      if new["lifecycle"] in ~w(finished abandoned),
        do:
          Map.put(
            new,
            "terminal_at",
            new["terminal_at"] ||
              DB.one("SELECT terminal_at FROM rooms WHERE id=$1", [DB.uuid(new["room_id"])])[
                "terminal_at"
              ] || now
          ),
        else: new

    rid = DB.uuid(new["room_id"])

    DB.query(
      "UPDATE rooms SET state_json=$2,lifecycle=$3,deadline_at=$4,revision=revision+1,updated_at=$5 WHERE id=$1",
      [rid, new, new["lifecycle"], new["deadline"], now]
    )

    for m <- new["members"] do
      DB.query(
        "UPDATE room_members SET role_code=$3,status=$4,control_generation=$5,device_id=$6 WHERE room_id=$1 AND id=$2",
        [
          rid,
          DB.uuid(m["id"]),
          m["role"],
          if(m["left"], do: "left", else: "joined"),
          m["generation"],
          if(m["device"], do: DB.uuid(m["device"]), else: nil)
        ]
      )

      before = if Rules.member(old, m["id"]), do: Rules.project(old, m["id"]), else: %{}
      after_view = Rules.project(new, m["id"])
      replace = Map.new(Enum.filter(after_view, fn {k, v} -> before[k] != v end))

      if map_size(replace) > 0 do
        seq =
          DB.one(
            "UPDATE room_members SET view_seq=view_seq+1 WHERE room_id=$1 AND id=$2 RETURNING view_seq",
            [rid, DB.uuid(m["id"])]
          )["view_seq"]

        e = %{
          "protocol_version" => 1,
          "recovery_epoch" => Util.epoch(),
          "seq" => seq,
          "event_id" => Util.id(),
          "type" => type,
          "phase_id" => new["phase_id"],
          "occurred_at" => Util.iso(now),
          "payload" => %{"replace" => replace}
        }

        DB.query(
          "INSERT INTO member_view_events(room_id,member_id,seq,event_json) VALUES($1,$2,$3,$4)",
          [rid, DB.uuid(m["id"]), seq, e]
        )

        DB.query("INSERT INTO outbox(room_id,member_id,seq) VALUES($1,$2,$3)", [
          rid,
          DB.uuid(m["id"]),
          seq
        ])
      end
    end

    for {item, i} <- new["items"],
        do:
          DB.query(
            "INSERT INTO room_items(room_id,item_id,owner_member_id,version) VALUES($1,$2,$3,$4) ON CONFLICT(room_id,item_id) DO UPDATE SET owner_member_id=$3,version=$4",
            [rid, item, DB.uuid(i["owner"]), i["version"]]
          )

    for o <- new["offers"],
        do:
          DB.query(
            "INSERT INTO item_offers(room_id,id,from_member_id,to_member_id,item_id,status,expires_at,item_version) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(room_id,id) DO UPDATE SET status=$6",
            [
              rid,
              DB.uuid(o["id"]),
              DB.uuid(o["from"]),
              DB.uuid(o["to"]),
              o["item_id"],
              o["status"],
              o["expires"],
              o["version"]
            ]
          )

    if new["round"] do
      r = new["round"]
      round = DB.uuid(r["round_id"])

      DB.query(
        "INSERT INTO vote_rounds(room_id,id,options_json,display_options_json,status) VALUES($1,$2,$3,$4,$5) ON CONFLICT(room_id,id) DO UPDATE SET status=$5",
        [rid, round, r["options"], r["display_options"], r["status"]]
      )

      for {mid, option} <- new["votes"],
          do:
            DB.query(
              "INSERT INTO votes(room_id,round_id,member_id,option_id) VALUES($1,$2,$3,$4) ON CONFLICT(room_id,round_id,member_id) DO UPDATE SET option_id=$4",
              [rid, round, DB.uuid(mid), option]
            )

      if r["status"] == "settled",
        do:
          DB.query(
            "INSERT INTO vote_settlements(room_id,round_id,winner,tally) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",
            [rid, round, r["winner"], r["tally"]]
          )
    end

    for m <- new["members"] do
      h = m["hint_pending"]

      if h do
        basis = %{
          "room_id" => new["room_id"],
          "member_id" => m["id"],
          "phase_id" => new["phase_id"],
          "knowledge_hash" => Rules.knowledge_hash(new, m["id"]),
          "hint_slot" => m["hint_used"] + 1,
          "reservation_id" => h["reservation"],
          "prompt_version" => "hint-v1"
        }

        input = %{
          "own_role" => m["role"],
          "known_clues" => m["known"],
          "public_clues" => new["shared"],
          "hint_level" => h["level"],
          "template" => Rules.hint_text(new, m["id"], h["level"])
        }

        authorized = Rules.project(new, m["id"])

        details =
          Enum.uniq_by(
            authorized["own_clues"] ++ authorized["public_scene"]["shared_clues"],
            & &1["clue_id"]
          )

        input = Map.put(input, "clue_details", details)

        DB.query(
          "INSERT INTO work_items(id,room_id,member_id,phase_id,reservation_id,kind,input_json,basis,status,created_at) VALUES($1,$2,$3,$4,$5,'player_hint',$6,$7,'queued',$8) ON CONFLICT DO NOTHING",
          [
            DB.uuid(h["job_id"]),
            rid,
            DB.uuid(m["id"]),
            DB.uuid(new["phase_id"]),
            DB.uuid(h["reservation"]),
            input,
            basis,
            now
          ]
        )
      end
    end

    new
  end

  def command(ctx, c, owner) do
    DB.transaction(fn ->
      Contract.command!(c)
      row = load!(ctx.room, true)
      s = row["state_json"]
      auth!(s, ctx)
      Util.require!(c["control_generation"] == ctx.generation, "CONTROL_REPLACED")
      Util.require!(c["recovery_epoch"] == Util.epoch(), "RECOVERY_CHANGED")
      now = DB.time()

      Util.require!(
        row["owner_instance"] == owner and row["lease_until"] > now,
        "OWNER_UNAVAILABLE"
      )

      hash = Contract.digest(c)

      saved =
        DB.one(
          "SELECT * FROM room_commands WHERE room_id=$1 AND member_id=$2 AND command_id=$3",
          [DB.uuid(ctx.room), DB.uuid(ctx.member), DB.uuid(c["command_id"])]
        )

      if saved do
        Util.require!(saved["payload_hash"] == hash, "IDEMPOTENCY_CONFLICT")
        saved["response_json"]
      else
        ticked = Rules.tick(s, now)
        s = if ticked != s, do: save(s, ticked, "phase_changed", now), else: s

        outcome =
          try do
            Util.require!(c["phase_id"] == s["phase_id"], "PHASE_CHANGED")

            availability =
              DB.one("SELECT availability FROM content_versions WHERE id=$1", [
                DB.uuid(s["content_version_id"])
              ])["availability"]

            Util.require!(availability != "blocked", "CONTENT_BLOCKED")

            p =
              if c["type"] == "offer_item",
                do: Map.put(c["payload"], "target_version", c["target_version"]),
                else: c["payload"]

            {:ok, Rules.apply(s, ctx.member, c["type"], p, now)}
          catch
            {:error, code} -> {:error, code}
          end

        trace = Util.id()

        {status, result} =
          case outcome do
            {:ok, {new, result, type}} ->
              new =
                if new["lifecycle"] == "lobby",
                  do: Map.put(new, "deadline", now + 1_800_000),
                  else: new

              if new != s, do: save(s, new, type, now)
              {"committed", %{"result" => result}}

            {:error, code} ->
              {"rejected", %{"error" => Map.put(Util.error(code), "trace_id", trace)}}
          end

        seq =
          DB.one("SELECT view_seq FROM room_members WHERE room_id=$1 AND id=$2", [
            DB.uuid(ctx.room),
            DB.uuid(ctx.member)
          ])["view_seq"]

        reply =
          Map.merge(
            %{
              "command_id" => c["command_id"],
              "status" => status,
              "receipt_seq" => seq,
              "trace_id" => trace
            },
            result
          )

        DB.query(
          "INSERT INTO room_commands(room_id,member_id,command_id,payload_hash,response_json) VALUES($1,$2,$3,$4,$5)",
          [DB.uuid(ctx.room), DB.uuid(ctx.member), DB.uuid(c["command_id"]), hash, reply]
        )

        reply
      end
    end)
  end

  def snapshot(ctx) do
    DB.transaction(fn ->
      Auth.valid!(ctx)
      row = load!(ctx.room, true)
      auth!(row["state_json"], ctx)

      m =
        DB.one("SELECT view_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(ctx.room),
          DB.uuid(ctx.member)
        ])

      %{
        "snapshot" =>
          Rules.project(Map.put(row["state_json"], "terminal_at", row["terminal_at"]), ctx.member),
        "base_seq" => m["view_seq"],
        "recovery_epoch" => Util.epoch(),
        "protocol_version" => 1,
        "server_time" => Util.iso(DB.time())
      }
    end)
  end

  def sync_baseline(ctx, p) do
    DB.transaction(fn ->
      Auth.valid!(ctx)
      row = load!(ctx.room, true)
      auth!(row["state_json"], ctx)

      cursor =
        DB.one("SELECT view_seq,replay_floor_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(ctx.room),
          DB.uuid(ctx.member)
        ])

      replay =
        p["has_snapshot"] and p["recovery_epoch"] == Util.epoch() and
          p["last_seq"] >= cursor["replay_floor_seq"] and p["last_seq"] <= cursor["view_seq"] and
          cursor["view_seq"] - p["last_seq"] <= 200

      %{
        "mode" => if(replay, do: "replay", else: "snapshot"),
        "base_seq" => if(replay, do: p["last_seq"], else: cursor["view_seq"]),
        "snapshot" =>
          if(replay,
            do: nil,
            else:
              Rules.project(
                Map.put(row["state_json"], "terminal_at", row["terminal_at"]),
                ctx.member
              )
          ),
        "protocol_version" => 1,
        "recovery_epoch" => Util.epoch(),
        "server_time" => Util.iso(DB.time())
      }
    end)
  end

  def events(ctx, after_seq, epoch, through \\ nil, limit \\ 200) do
    DB.transaction(fn ->
      Auth.valid!(ctx)
      row = load!(ctx.room, true)
      auth!(row["state_json"], ctx)
      Util.require!(epoch == Util.epoch(), "RECOVERY_CHANGED")

      m =
        DB.one("SELECT view_seq,replay_floor_seq FROM room_members WHERE room_id=$1 AND id=$2", [
          DB.uuid(ctx.room),
          DB.uuid(ctx.member)
        ])

      Util.require!(after_seq >= m["replay_floor_seq"], "RESYNC_REQUIRED")
      Util.require!(after_seq <= m["view_seq"], "CURSOR_AHEAD")
      h = through || m["view_seq"]
      Util.require!(h <= m["view_seq"] and h >= after_seq, "CURSOR_AHEAD")

      es =
        DB.rows(
          "SELECT event_json FROM member_view_events WHERE room_id=$1 AND member_id=$2 AND seq>$3 AND seq<=$4 ORDER BY seq LIMIT $5",
          [DB.uuid(ctx.room), DB.uuid(ctx.member), after_seq, h, min(200, limit)]
        )
        |> Enum.map(& &1["event_json"])

      next = if es == [], do: after_seq, else: List.last(es)["seq"]

      %{
        "events" => es,
        "next_after_seq" => next,
        "high_watermark" => h,
        "has_more" => next < h,
        "recovery_epoch" => Util.epoch()
      }
    end)
  end

  def receipt(ctx, cid) do
    DB.transaction(fn ->
      Auth.valid!(ctx)
      row = load!(ctx.room, true)
      auth!(row["state_json"], ctx)

      r =
        DB.one(
          "SELECT response_json FROM room_commands WHERE room_id=$1 AND member_id=$2 AND command_id=$3",
          [DB.uuid(ctx.room), DB.uuid(ctx.member), DB.uuid(cid)]
        )

      Util.require!(r != nil, "COMMAND_NOT_FOUND")
      r["response_json"]
    end)
  end
end

defmodule Ruxi.RoomServer do
  use GenServer
  alias Ruxi.{DB, Store, Rules, Util}

  def ensure(rid) do
    case Registry.lookup(Ruxi.RoomRegistry, rid) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(Ruxi.RoomSupervisor, {__MODULE__, rid}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  def start_link(rid),
    do: GenServer.start_link(__MODULE__, rid, name: {:via, Registry, {Ruxi.RoomRegistry, rid}})

  def command(ctx, c) do
    {:ok, pid} = ensure(ctx.room)
    GenServer.call(pid, {:command, ctx, c})
  end

  def presence(ctx, on) do
    {:ok, pid} = ensure(ctx.room)
    GenServer.call(pid, {:presence, ctx, on})
  end

  def init(rid) do
    instance = System.get_env("CORE_INSTANCE", "local")
    owner = instance <> ":" <> Util.id()

    lease =
      DB.transaction(fn ->
        row = Store.load!(rid, true)
        now = DB.time()

        Util.require!(
          is_nil(row["owner_instance"]) or row["lease_until"] <= now or
            String.starts_with?(row["owner_instance"], instance <> ":"),
          "OWNER_UNAVAILABLE"
        )

        DB.query(
          "UPDATE rooms SET owner_instance=$2,owner_epoch=owner_epoch+1,lease_until=$3 WHERE id=$1",
          [DB.uuid(rid), owner, now + 15_000]
        )

        s = row["state_json"]

        n =
          Enum.reduce(s["members"], s, fn m, acc ->
            online = Ruxi.Connections.online?(rid, m["id"], m["generation"])

            if online != m["online"],
              do:
                Rules.update_member(
                  acc,
                  m["id"],
                  &Map.merge(&1, %{"online" => online, "offline_at" => now})
                ),
              else: acc
          end)

        n = Rules.tick(n, now)
        if n != s, do: Store.save(s, n, "member_changed", now)
      end)

    case lease do
      {:ok, _} ->
        Process.send_after(self(), :tick, 1000)
        {:ok, %{rid: rid, owner: owner}}

      {:error, code} ->
        {:stop, code}
    end
  end

  def handle_call({:command, ctx, c}, _, st), do: {:reply, Store.command(ctx, c, st.owner), st}

  def handle_call({:presence, ctx, on}, _, st) do
    r =
      DB.transaction(fn ->
        row = Store.load!(st.rid, true)
        s = row["state_json"]
        Store.auth!(s, ctx)
        now = DB.time()

        Util.require!(
          row["owner_instance"] == st.owner and row["lease_until"] > now,
          "OWNER_UNAVAILABLE"
        )

        n = Rules.presence(s, ctx.member, on, now)
        if n != s, do: Store.save(s, n, "member_changed", now)
        :ok
      end)

    {:reply, r, st}
  end

  def handle_info(:tick, st) do
    DB.transaction(fn ->
      row = Store.load!(st.rid, true)
      now = DB.time()
      Util.require!(row["owner_instance"] == st.owner, "OWNER_UNAVAILABLE")
      DB.query("UPDATE rooms SET lease_until=$2 WHERE id=$1", [DB.uuid(st.rid), now + 15_000])
      s = row["state_json"]
      n = Rules.tick(s, now)

      blocked =
        DB.one("SELECT availability FROM content_versions WHERE id=$1", [
          DB.uuid(s["content_version_id"])
        ])["availability"] == "blocked"

      n =
        if blocked and n["lifecycle"] == "running" and n["phase"] != "ending",
          do: Rules.block(n, now),
          else: n

      if n != s, do: Store.save(s, n, "phase_changed", now)
    end)

    Process.send_after(self(), :tick, 1000)
    {:noreply, st}
  end
end

defmodule Ruxi.Dispatcher do
  use GenServer
  alias Ruxi.DB
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_),
    do:
      (
        Process.send_after(self(), :dispatch, 100)
        {:ok, nil}
      )

  def handle_info(:dispatch, s) do
    try do
      if rem(System.monotonic_time(:second), 5) == 0 do
        for row <-
              DB.rows("SELECT id FROM rooms WHERE lifecycle IN ('running','paused','suspended')"),
            do: Ruxi.RoomServer.ensure(DB.str(row["id"]))
      end

      for r <-
            DB.rows(
              "SELECT o.id,o.room_id,o.member_id,e.event_json FROM outbox o JOIN member_view_events e USING(room_id,member_id,seq) WHERE o.delivered_at IS NULL ORDER BY o.id LIMIT 200"
            ) do
        topic = "player_room:#{DB.str(r["room_id"])}:#{DB.str(r["member_id"])}"
        RuxiWeb.Endpoint.broadcast(topic, "view_event", r["event_json"])

        DB.query("UPDATE outbox SET delivered_at=$2 WHERE id=$1 AND delivered_at IS NULL", [
          r["id"],
          Ruxi.Util.now()
        ])
      end
    rescue
      _ -> :ok
    end

    Process.send_after(self(), :dispatch, 100)
    {:noreply, s}
  end
end
