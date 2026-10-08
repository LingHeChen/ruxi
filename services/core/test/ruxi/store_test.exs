defmodule Ruxi.StoreTest do
  use ExUnit.Case
  alias Ruxi.{DB, Util, Auth, Store}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    Ruxi.Content.seed()
    device = Util.id()
    {:ok, a} = Auth.guest(%{"device_id" => device, "command_id" => Util.id()})
    ctx = Auth.authenticate(a["access_token"])

    {:ok, r} =
      Auth.create_room(ctx, %{"story_id" => Ruxi.Content.story_id(), "command_id" => Util.id()})

    {:ok, t} = Auth.ticket(ctx, r["room_id"], %{"device_id" => device, "takeover" => false})
    ctx = Auth.member_context(ctx, r["room_id"], device, t["control_generation"])

    DB.query("UPDATE rooms SET owner_instance='test',lease_until=$2 WHERE id=$1", [
      DB.uuid(ctx.room),
      DB.time() + 15_000
    ])

    %{ctx: ctx, auth: a}
  end

  def cmd(ctx, t, p),
    do: %{
      "protocol_version" => 1,
      "command_id" => Util.id(),
      "recovery_epoch" => Util.epoch(),
      "phase_id" => nil,
      "control_generation" => ctx.generation,
      "type" => t,
      "payload" => p
    }

  def worker(path, p),
    do:
      Ruxi.Jobs.dispatch(path, p, %{
        "worker_id" => "test-worker",
        "allowed_kinds" => ["player_hint"]
      })

  test "join chooses replay only with a valid authorized baseline and retained history", %{
    ctx: ctx
  } do
    {:ok, initial} = Store.snapshot(ctx)

    p = %{
      "has_snapshot" => true,
      "last_seq" => initial["base_seq"],
      "recovery_epoch" => Util.epoch()
    }

    {:ok, replay} = Store.sync_baseline(ctx, p)
    assert replay["mode"] == "replay" and replay["snapshot"] == nil

    {:ok, _} =
      Store.command(ctx, cmd(ctx, "select_role", %{"role_code" => "investigator"}), "test")

    {:ok, replay} = Store.sync_baseline(ctx, p)
    assert replay["base_seq"] == initial["base_seq"]
    {:ok, tail} = Store.events(ctx, replay["base_seq"], Util.epoch())
    assert length(tail["events"]) == 1
    {:ok, snap} = Store.sync_baseline(ctx, Map.put(p, "recovery_epoch", "old-epoch"))
    assert snap["mode"] == "snapshot" and snap["snapshot"]["self"]["role_code"] == "investigator"
    {:ok, snap} = Store.sync_baseline(ctx, Map.put(p, "last_seq", snap["base_seq"] + 1))
    assert snap["mode"] == "snapshot"

    DB.query("UPDATE room_members SET replay_floor_seq=view_seq WHERE room_id=$1 AND id=$2", [
      DB.uuid(ctx.room),
      DB.uuid(ctx.member)
    ])

    {:ok, snap} = Store.sync_baseline(ctx, p)
    assert snap["mode"] == "snapshot"
  end

  test "one receipt and one effect for ten identical retries; conflict on changed intent", %{
    ctx: ctx
  } do
    c = cmd(ctx, "select_role", %{"role_code" => "investigator"})
    {:ok, r} = Store.command(ctx, c, "test")
    assert r["status"] == "committed"
    for _ <- 1..10, do: assert(Store.command(ctx, c, "test") == {:ok, r})

    assert DB.one("SELECT count(*) AS n FROM room_commands WHERE room_id=$1", [DB.uuid(ctx.room)])[
             "n"
           ] == 1

    assert Store.command(ctx, put_in(c, ["payload", "role_code"], "passenger"), "test") ==
             {:error, "IDEMPOTENCY_CONFLICT"}
  end

  test "private snapshot cannot be read with another device; takeover can query original receipt",
       %{ctx: ctx} do
    c = cmd(ctx, "select_role", %{"role_code" => "investigator"})
    {:ok, r} = Store.command(ctx, c, "test")
    new_device = Util.id()

    {:ok, t} =
      Auth.ticket(ctx, ctx.room, %{
        "device_id" => new_device,
        "takeover" => true,
        "command_id" => Util.id()
      })

    assert Store.snapshot(ctx) == {:error, "CONTROL_REPLACED"}
    next = %{ctx | device: new_device, generation: t["control_generation"]}
    assert Store.receipt(next, c["command_id"]) == {:ok, r}

    assert Store.command(next, Map.put(c, "control_generation", next.generation), "test") ==
             {:ok, r}
  end

  test "owner fencing and epoch checked before saved receipt", %{ctx: ctx} do
    c = cmd(ctx, "select_role", %{"role_code" => "investigator"})
    {:ok, _} = Store.command(ctx, c, "test")
    assert Store.command(ctx, c, "other") == {:error, "OWNER_UNAVAILABLE"}

    assert Store.command(ctx, Map.put(c, "recovery_epoch", "old"), "test") ==
             {:error, "RECOVERY_CHANGED"}
  end

  test "account retries do not create two rooms", %{ctx: ctx} do
    p = %{"story_id" => Ruxi.Content.story_id(), "command_id" => Util.id()}
    assert Auth.create_room(ctx, p) == Auth.create_room(ctx, p)
  end

  test "snapshot and durable events use the same member stream", %{ctx: ctx} do
    c = cmd(ctx, "select_role", %{"role_code" => "investigator"})
    {:ok, r} = Store.command(ctx, c, "test")
    {:ok, s} = Store.snapshot(ctx)
    assert s["base_seq"] == r["receipt_seq"]
    {:ok, e} = Store.events(ctx, 0, Util.epoch())
    assert e["next_after_seq"] == s["base_seq"]
    assert Enum.map(e["events"], & &1["seq"]) == Enum.to_list(1..s["base_seq"])
    refute Jason.encode!(s["snapshot"]) =~ "owner_instance"
  end

  test "guest recovery rotates code, revokes old session, restores same user", %{
    ctx: ctx,
    auth: a
  } do
    p = %{
      "device_id" => Util.id(),
      "recovery_code" => a["recovery_code"],
      "recovery_request_id" => Util.id()
    }

    {:ok, n} = Auth.recover(p)
    assert n["user_id"] == ctx.user
    refute n["recovery_code"] == a["recovery_code"]
    assert Auth.recover(p) == {:ok, n}
    assert catch_throw(Auth.authenticate(a["access_token"])) == {:error, "UNAUTHORIZED"}
  end

  test "fallback and late worker compete for one hint slot; complete receipt survives expired lease",
       %{ctx: ctx} do
    s = Store.load!(ctx.room)["state_json"]
    now = DB.time()

    n =
      s
      |> Map.merge(%{
        "lifecycle" => "running",
        "phase" => "exploration",
        "phase_id" => Util.id(),
        "step" => "active",
        "deadline" => now + 180_000
      })
      |> Ruxi.Rules.update_member(
        ctx.member,
        &Map.merge(&1, %{"role" => "investigator", "online" => true})
      )

    Store.save(s, n, "phase_changed", now)
    c = cmd(ctx, "request_hint", %{"hint_level" => 1}) |> Map.put("phase_id", n["phase_id"])
    {:ok, r} = Store.command(ctx, c, "test")
    assert r["status"] == "committed"

    {:ok, job} =
      worker(["claim"], %{
        "worker_id" => "test-worker",
        "supported_kinds" => ["player_hint"],
        "claim_id" => Util.id()
      })

    s = Store.load!(ctx.room)["state_json"]
    n = Ruxi.Rules.tick(s, now + 9_000)
    Store.save(s, n, "hint_ready", now + 9_000)
    result = %{"narrative" => "只查看你已知的信息。", "evidence_ids" => []}

    body = %{
      "attempt" => job["attempt"],
      "lease_token" => job["lease_token"],
      "result_hash" => Util.hash(result),
      "result" => result
    }

    assert Ruxi.Jobs.dispatch([job["job_id"], "complete"], body, %{
             "worker_id" => "other-worker",
             "allowed_kinds" => ["player_hint"]
           }) == {:error, "NOT_ALLOWED"}

    assert worker([job["job_id"], "complete"], body) ==
             {:ok, %{"status" => "ignored"}}

    DB.query("UPDATE work_items SET lease_until=0 WHERE id=$1", [DB.uuid(job["job_id"])])

    assert worker([job["job_id"], "complete"], body) ==
             {:ok, %{"status" => "ignored"}}

    assert worker(
             [job["job_id"], "complete"],
             Map.put(body, "result_hash", String.duplicate("0", 64))
           ) == {:error, "RESULT_CONFLICT"}

    {:ok, snap} = Store.snapshot(ctx)
    assert snap["snapshot"]["hints"]["remaining"] == 1
    assert length(snap["snapshot"]["hints"]["entries"]) == 1
  end

  test "a genuine nonretryable worker failure releases its hint reservation", %{ctx: ctx} do
    now = DB.time()
    s = Store.load!(ctx.room)["state_json"]

    n =
      s
      |> Map.merge(%{
        "lifecycle" => "running",
        "phase" => "exploration",
        "step" => "active",
        "phase_id" => Util.id(),
        "deadline" => now + 180_000
      })
      |> Ruxi.Rules.update_member(
        ctx.member,
        &Map.merge(&1, %{"role" => "investigator", "online" => true})
      )

    Store.save(s, n, "phase_changed", now)
    command = cmd(ctx, "request_hint", %{"hint_level" => 1}) |> Map.put("phase_id", n["phase_id"])
    {:ok, _} = Store.command(ctx, command, "test")

    {:ok, job} =
      worker(["claim"], %{
        "worker_id" => "test-worker",
        "supported_kinds" => ["player_hint"],
        "claim_id" => Util.id()
      })

    assert worker([job["job_id"], "fail"], %{
             "attempt" => job["attempt"],
             "lease_token" => job["lease_token"],
             "code" => "INVALID_OUTPUT",
             "retryable" => false
           }) == {:ok, %{"status" => "failed"}}

    {:ok, snapshot} = Store.snapshot(ctx)
    assert snapshot["snapshot"]["hints"]["remaining"] == 2
    assert snapshot["snapshot"]["hints"]["pending_job_id"] == nil
  end

  test "strict JSON rejects duplicate keys before command interpretation" do
    assert_raise ArgumentError, fn ->
      Ruxi.StrictJSON.decode!(~s({"ready":true,"ready":false}))
    end
  end

  test "authorized media signs a range-capable clip, private assets remain unavailable", %{
    ctx: ctx
  } do
    s = Store.load!(ctx.room)["state_json"]

    n =
      s
      |> Map.merge(%{
        "lifecycle" => "running",
        "phase" => "briefing",
        "phase_id" => Util.id(),
        "media_epochs" => %{"opening" => 1}
      })
      |> Ruxi.Rules.update_member(ctx.member, &Map.put(&1, "role", "investigator"))

    Store.save(s, n, "phase_changed", DB.time())

    {:ok, a} =
      Ruxi.Media.access(
        ctx,
        %{
          "room_id" => ctx.room,
          "device_id" => ctx.device,
          "control_generation" => ctx.generation,
          "asset_id" => Ruxi.Content.asset_id("opening")
        },
        "http://localhost:4000"
      )

    assert a["duration_ms"] == 50_000
    cap = a["url"] |> String.split("/media/") |> List.last()
    conn = Plug.Test.conn(:get, "/media/x") |> Plug.Conn.put_req_header("range", "bytes=0-1023")
    assert Ruxi.Media.stream(conn, cap).status == 206

    assert Ruxi.Media.access(
             ctx,
             %{
               "room_id" => ctx.room,
               "device_id" => ctx.device,
               "control_generation" => ctx.generation,
               "asset_id" => Ruxi.Content.asset_id("role_passenger")
             },
             "http://localhost:4000"
           ) == {:error, "RESOURCE_NOT_FOUND"}
  end

  test "account semantic rejection is durable and same ID different payload conflicts", %{
    ctx: ctx
  } do
    p = %{"invite_code" => "XXXXXXXX", "command_id" => Util.id()}
    assert Auth.join_room(ctx, p) == {:error, "INVITE_UNAVAILABLE"}
    assert Auth.join_room(ctx, p) == {:error, "INVITE_UNAVAILABLE"}

    assert DB.one(
             "SELECT count(*) AS n FROM account_commands WHERE user_id=$1 AND operation='room.join'",
             [DB.uuid(ctx.user)]
           )["n"] == 1

    assert Auth.join_room(ctx, Map.put(p, "invite_code", "YYYYYYYY")) ==
             {:error, "IDEMPOTENCY_CONFLICT"}
  end

  test "cross-room item owner is rejected by PostgreSQL", %{ctx: ctx} do
    error =
      assert_raise Postgrex.Error, fn ->
        DB.query(
          "INSERT INTO room_items(room_id,item_id,owner_member_id,version) VALUES($1,'C2',$2,1)",
          [DB.uuid(ctx.room), DB.uuid(Util.id())]
        )
      end

    assert error.postgres.code == :foreign_key_violation
  end

  test "published graph is immutable at the database layer" do
    error =
      assert_raise Postgrex.Error, fn ->
        DB.query(
          "UPDATE content_versions SET graph=jsonb_set(graph,'{title}','\"changed\"') WHERE id=$1",
          [DB.uuid(Ruxi.Content.version_id())]
        )
      end

    assert error.postgres.code == :raise_exception
  end

  test "admin version flow freezes a new version without changing an existing room", %{
    ctx: player
  } do
    user = Util.id()
    device = Util.id()
    code = Util.token()
    DB.query("INSERT INTO users(id,display_name) VALUES($1,'测试编辑')", [DB.uuid(user)])

    for role <- ~w(editor reviewer publisher),
        do: DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,$2)", [DB.uuid(user), role])

    DB.query(
      "INSERT INTO admin_login_codes(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)",
      [DB.uuid(Util.id()), DB.uuid(user), Util.hash(code), DB.time() + 300_000]
    )

    {:ok, a} =
      Auth.admin_exchange(%{
        "login_code" => code,
        "device_id" => device,
        "login_request_id" => Util.id()
      })

    admin = Auth.authenticate(a["access_token"], "admin")
    assert catch_throw(Auth.authenticate(a["access_token"], "player")) == {:error, "NOT_ALLOWED"}

    {:ok, created} =
      Ruxi.Admin.dispatch(
        "POST",
        ["stories", Ruxi.Content.story_id(), "versions"],
        %{"base_version_id" => Ruxi.Content.version_id(), "command_id" => Util.id()},
        admin
      )

    id = created["version_id"]
    v = Ruxi.Admin.dispatch("GET", ["versions", id], %{}, admin)
    room_count = DB.one("SELECT count(*) AS n FROM rooms")["n"]
    preview_request = %{"revision" => 1, "command_id" => Util.id()}

    {:ok, preview} =
      Ruxi.Admin.dispatch("POST", ["versions", id, "preview"], preview_request, admin)

    assert Ruxi.Admin.dispatch("POST", ["versions", id, "preview"], preview_request, admin) ==
             {:ok, preview}

    assert map_size(preview["views"]) == 3

    preview_step = %{
      "preview_token" => preview["preview_token"],
      "actor_role" => "investigator",
      "type" => "media_complete",
      "payload" => %{"media_id" => "opening", "media_epoch" => 1, "mode" => "summary"},
      "command_id" => Util.id()
    }

    {:ok, stepped} = Ruxi.Admin.dispatch("POST", ["previews", "step"], preview_step, admin)
    assert stepped["steps"] == 1

    assert Ruxi.Admin.dispatch("POST", ["previews", "step"], preview_step, admin) ==
             {:ok, stepped}

    assert Ruxi.Admin.dispatch(
             "POST",
             ["previews", "step"],
             Map.put(preview_step, "actor_role", "passenger"),
             admin
           ) == {:error, "IDEMPOTENCY_CONFLICT"}

    assert DB.one("SELECT count(*) AS n FROM rooms")["n"] == room_count

    {:ok, j} =
      Ruxi.Admin.dispatch(
        "POST",
        ["versions", id, "validate"],
        %{"revision" => 1, "command_id" => Util.id()},
        admin
      )

    assert Ruxi.Admin.dispatch("GET", ["jobs", j["job_id"]], %{}, admin)["valid"]

    {:ok, approved} =
      Ruxi.Admin.dispatch(
        "POST",
        ["versions", id, "approve"],
        %{"revision" => 1, "content_hash" => v["hash"], "command_id" => Util.id()},
        admin
      )

    {:ok, published} =
      Ruxi.Admin.dispatch(
        "POST",
        ["versions", id, "publish"],
        %{
          "revision" => 1,
          "approved_hash" => approved["approved_hash"],
          "command_id" => Util.id()
        },
        admin
      )

    assert published["content_version_id"] == id

    assert Store.load!(player.room)["state_json"]["content_version_id"] ==
             Ruxi.Content.version_id()

    {:ok, new} =
      Auth.create_room(player, %{"story_id" => Ruxi.Content.story_id(), "command_id" => Util.id()})

    assert new["content_version_id"] == id

    assert catch_throw(
             Ruxi.Admin.dispatch(
               "POST",
               ["versions", id, "publish"],
               %{"revision" => 1, "approved_hash" => v["hash"], "command_id" => Util.id()},
               player
             )
           ) == {:error, "NOT_ALLOWED"}
  end
end
