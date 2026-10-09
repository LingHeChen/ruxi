defmodule Ruxi.C2.StoreTest do
  use ExUnit.Case
  alias Ruxi.{Auth, DB, Util}
  alias Ruxi.C2.{Studio, Store}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)

    people =
      Enum.map(1..3, fn _ ->
        {:ok, a} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
        Auth.authenticate(a["access_token"])
      end)

    admin = hd(people)

    for role <- ~w(editor reviewer publisher),
        do:
          DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,$2)", [
            DB.uuid(admin.user),
            role
          ])

    story =
      File.read!(Path.expand("../../../content/c2/restaurant.json", __DIR__)) |> Jason.decode!()

    {:ok, project} =
      DB.transaction(fn ->
        Studio.create(admin, %{"title" => story["title"], "seat_count" => 3})
      end)

    id = project["id"]
    {:ok, _} = DB.transaction(fn -> Studio.save(admin, id, story, 1) end)
    hash = Util.hash(story)

    {:ok, _} =
      DB.transaction(fn ->
        Studio.review(admin, id, %{
          "decision" => "approve",
          "reason" => "规则验收",
          "content_hash" => hash
        })
      end)

    {:ok, release} =
      DB.transaction(fn -> Studio.publish(admin, id, %{"content_hash" => hash}) end)

    {:ok, room} =
      DB.transaction(fn -> Store.create(admin, %{"release_id" => release["release_id"]}) end)

    for ctx <- tl(people),
        do:
          assert(
            {:ok, _} =
              DB.transaction(fn -> Store.join(ctx, %{"invite_code" => room["invite_code"]}) end)
          )

    %{people: people, room: room, project: id, release: release}
  end

  def cmd(type, body),
    do: %{
      "protocol_version" => 2,
      "step_id" => nil,
      "command_id" => Util.id(),
      "control_epoch" => 1,
      "type" => type,
      "body" => body
    }

  test "published content is frozen and drafts use optimistic revisions", s do
    assert {:error, "REVISION_CONFLICT"} =
             DB.transaction(fn -> Studio.save(hd(s.people), s.project, %{}, 1) end)

    row =
      DB.one("SELECT content_hash,content FROM c2_releases WHERE id=$1", [
        DB.uuid(s.release["release_id"])
      ])

    assert row["content_hash"] == Util.hash(row["content"])

    assert DB.one(
             "SELECT table_schema FROM information_schema.tables WHERE table_name='c2_rooms'"
           )["table_schema"] == "ruxi"
  end

  test "three real members start, reserve AP, retry commands and receive private snapshots", s do
    for {ctx, role} <- Enum.zip(s.people, ~w(guest doctor reporter)) do
      assert {:ok, _} =
               Store.command(
                 ctx,
                 s.room["room_id"],
                 cmd("role.select", %{"role_id" => role})
               )

      assert {:ok, _} =
               Store.command(ctx, s.room["room_id"], cmd("member.ready", %{"ready" => true}))
    end

    assert {:ok, _} = Store.command(hd(s.people), s.room["room_id"], cmd("room.start", %{}))
    assert {:ok, view} = Store.snapshot(hd(s.people), s.room["room_id"])
    assert view["protocol_version"] == 2

    assert DB.one("SELECT count(*) AS n FROM c2_actor_states WHERE room_id=$1", [
             DB.uuid(s.room["room_id"])
           ])["n"] == 3

    c = cmd("room.leave", %{})
    assert {:ok, receipt} = Store.command(hd(s.people), s.room["room_id"], c)
    assert {:ok, ^receipt} = Store.command(hd(s.people), s.room["room_id"], c)

    assert {:error, "IDEMPOTENCY_CONFLICT"} =
             Store.command(hd(s.people), s.room["room_id"], Map.put(c, "type", "room.resume"))
  end

  test "socket tickets are one-use and takeover fences the previous device", s do
    ctx = hd(s.people)
    id = s.room["room_id"]
    {:ok, t} = Store.ticket(ctx, id)
    assert {:ok, socket_ctx} = Store.consume_ticket(t["socket_ticket"])
    assert {:error, "UNAUTHORIZED"} = Store.consume_ticket(t["socket_ticket"])
    assert {:ok, _} = Store.heartbeat(socket_ctx)
    other = %{ctx | device: Util.id()}
    assert {:error, "TAKEOVER_REQUIRED"} = Store.ticket(other, id)
    assert {:ok, replacement} = Store.ticket(other, id, true)
    assert replacement["control_epoch"] == 2
    assert {:error, "STALE_CONTROL"} = Store.heartbeat(socket_ctx)

    assert {:error, "INVALID_ARGUMENT"} =
             Store.command(other, id, %{
               "protocol_version" => 2,
               "command_id" => Util.id(),
               "control_epoch" => 2,
               "step_id" => nil,
               "type" => "role.select",
               "body" => %{"role_id" => "guest", "extra" => "private-canary"}
             })
  end

  test "settled intents and private knowledge agree with normalized database facts", s do
    id = s.room["room_id"]

    for {ctx, role} <- Enum.zip(s.people, ~w(guest doctor reporter)) do
      {:ok, _} = Store.command(ctx, id, cmd("role.select", %{"role_id" => role}))
      {:ok, _} = Store.command(ctx, id, cmd("member.ready", %{"ready" => true}))
    end

    {:ok, _} = Store.command(hd(s.people), id, cmd("room.start", %{}))

    for ctx <- s.people do
      {:ok, snapshot} = Store.snapshot(ctx, id)

      for cue <- snapshot["blocks"]["narrative_cues"],
          do:
            assert(
              {:ok, _} =
                Store.command(
                  ctx,
                  id,
                  cmd("media.complete", %{"cue_id" => cue["id"], "mode" => "summary"})
                )
            )
    end

    for ctx <- tl(s.people) do
      {:ok, snapshot} = Store.snapshot(ctx, id)

      {:ok, _} =
        Store.command(
          ctx,
          id,
          Map.put(cmd("round.end", %{}), "step_id", snapshot["blocks"]["room"]["step_id"])
        )
    end

    {:ok, before} = Store.snapshot(hd(s.people), id)

    {:ok, _} =
      Store.command(
        hd(s.people),
        id,
        Map.put(
          cmd("action.submit", %{"action_id" => "ask", "target_id" => "waiter"}),
          "step_id",
          before["blocks"]["room"]["step_id"]
        )
      )

    {:ok, own} = Store.snapshot(hd(s.people), id)
    {:ok, other} = Store.snapshot(Enum.at(s.people, 1), id)
    assert Enum.any?(own["blocks"]["knowledge"], &(&1["id"] == "access"))
    refute Enum.any?(other["blocks"]["knowledge"], &(&1["id"] == "access"))
    assert own["blocks"]["self"]["ap_remaining"] == 2
    assert own["blocks"]["self"]["ap_reserved"] == 0

    assert DB.one("SELECT status,cost FROM c2_intents WHERE room_id=$1", [DB.uuid(id)]) == %{
             "status" => "resolved",
             "cost" => 1
           }

    assert DB.one("SELECT count(*) AS n FROM c2_step_settlements WHERE room_id=$1", [DB.uuid(id)])[
             "n"
           ] == 1
  end
end
