defmodule Ruxi.TestRtcGateway do
  def configured?, do: true
  def ready?, do: true
  def app_id, do: "fixture-app"

  def token(room, uid, expires),
    do: "test:" <> room <> ":" <> uid <> ":" <> Integer.to_string(expires)

  def retire(_), do: Process.get(:rtc_fence_result, :fenced)
end

defmodule Ruxi.SceneCommunicationTest do
  use ExUnit.Case, async: false
  alias Ruxi.{Auth, DB, Util}
  alias Ruxi.C2.{Communication, Store, Engine}
  alias Ruxi.SceneVoice.Coordinator, as: Voice

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ruxi.Repo)
    prior = Application.get_env(:ruxi, :scene_voice_gateway)
    Application.put_env(:ruxi, :scene_voice_gateway, Ruxi.TestRtcGateway)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:ruxi, :scene_voice_gateway, prior),
        else: Application.delete_env(:ruxi, :scene_voice_gateway)
    end)

    people =
      Enum.map(1..3, fn _ ->
        {:ok, a} = Auth.guest(%{"device_id" => Util.id(), "command_id" => Util.id()})
        Auth.authenticate(a["access_token"])
      end)

    story =
      File.read!(Path.expand("../../../content/c2/restaurant.json", __DIR__))
      |> Jason.decode!()
      |> Map.put("communication", %{"voice" => %{"enabled" => true, "scope" => "scene"}})

    project = Util.id()
    release = Util.id()
    now = DB.time()
    owner = hd(people)

    DB.query(
      "INSERT INTO c2_projects(id,owner_id,title,content,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$5)",
      [DB.uuid(project), DB.uuid(owner.user), story["title"], story, now]
    )

    DB.query("INSERT INTO c2_releases VALUES($1,$2,$3,$4,'published',$5,$6)", [
      DB.uuid(release),
      DB.uuid(project),
      Util.hash(story),
      story,
      DB.uuid(owner.user),
      now
    ])

    {:ok, room} = DB.transaction(fn -> Store.create(owner, %{"release_id" => release}) end)

    for ctx <- tl(people),
        do: DB.transaction(fn -> Store.join(ctx, %{"invite_code" => room["invite_code"]}) end)

    roles = Enum.map(story["roles"], & &1["id"])

    for {ctx, role} <- Enum.zip(people, roles),
        do:
          DB.query("UPDATE c2_room_members SET role_id=$3 WHERE room_id=$1 AND user_id=$2", [
            DB.uuid(room["room_id"]),
            DB.uuid(ctx.user),
            role
          ])

    state = Engine.initial(story, now, roles)

    DB.query("UPDATE c2_rooms SET state=$2,status='active' WHERE id=$1", [
      DB.uuid(room["room_id"]),
      state
    ])

    for ctx <- people do
      m = elem(Communication.context!(ctx, room["room_id"]), 1)

      Voice.socket_connected(
        Map.merge(ctx, %{room: room["room_id"], member: DB.str(m["id"])}),
        Util.id()
      )
    end

    %{people: people, id: room["room_id"], story: story}
  end

  def request(s, ctx, action, body) do
    state = Communication.voice(ctx, s.id)

    p = %{
      "voice_protocol_version" => 1,
      "request_id" => Util.id(),
      "control_epoch" => 1,
      "expected_revision" => state["voice_revision"],
      "action" => action,
      "body" => body
    }

    {p, Communication.voice_request(ctx, s.id, p)}
  end

  def join_pair(s) do
    for ctx <- Enum.take(s.people, 2),
        do: assert({_, {:ok, _}} = request(s, ctx, "participation", %{"enabled" => true}))

    {_p, {:ok, g}} = request(s, hd(s.people), "grant", %{})
    g
  end

  test "chat has frozen server-selected audiences, safe plaintext and no game/AP mutation", s do
    [a, b, c] = s.people
    {r, am} = Communication.context!(a, s.id)
    before = r["state"]
    bm = elem(Communication.context!(b, s.id), 1)
    cm = elem(Communication.context!(c, s.id), 1)
    # Colocate only a/b; a and c share a faction independent of location.
    roles = [am["role_id"], bm["role_id"], cm["role_id"]]

    state =
      Enum.reduce(
        Enum.zip(roles, [{"one", "red"}, {"one", "blue"}, {"two", "red"}]),
        before,
        fn {role, {loc, faction}}, s ->
          s
          |> put_in(["actors", role, "location"], loc)
          |> put_in(["actors", role, "faction"], faction)
        end
      )

    DB.query("UPDATE c2_rooms SET state=$2 WHERE id=$1", [r["id"], state])

    for {scope, readers} <- [{"scene", [a, b]}, {"faction", [a, c]}, {"global", [a, b, c]}] do
      p = %{
        "request_id" => Util.id(),
        "control_epoch" => 1,
        "scope" => scope,
        "text" => "<script>不可执行</script>"
      }

      assert {:ok, receipt} = Communication.send(a, s.id, p)
      assert {:ok, ^receipt} = Communication.send(a, s.id, p)

      assert {:error, "IDEMPOTENCY_CONFLICT"} =
               Communication.send(a, s.id, Map.put(p, "text", "different"))

      for ctx <- s.people do
        seen =
          Enum.any?(
            Communication.history(ctx, s.id)["messages"],
            &(&1["id"] == receipt["message_id"])
          )

        assert seen == ctx in readers
      end
    end

    assert elem(Communication.context!(a, s.id), 0)["state"] == state

    assert DB.one("SELECT count(*) AS n FROM c2_chat_messages WHERE room_id=$1", [r["id"]])["n"] ==
             3
  end

  test "one opted-in player never gets RTC, two get bound ephemeral credentials", s do
    a = hd(s.people)
    assert {_, {:ok, _}} = request(s, a, "participation", %{"enabled" => true})
    assert Communication.voice(a, s.id)["status"] == "waiting"
    assert {_, {:error, "NOT_READY"}} = request(s, a, "grant", %{})
    assert {_, {:ok, _}} = request(s, Enum.at(s.people, 1), "participation", %{"enabled" => true})
    {p, {:ok, g}} = request(s, a, "grant", %{})
    assert {:ok, replayed} = Communication.voice_request(a, s.id, p)
    assert g["lease_id"] == replayed["lease_id"]
    assert g["token_expires_at"] == replayed["token_expires_at"]
    assert String.contains?(g["token"], g["rtc_uid"])
    refute String.contains?(g["rtc_room_id"], s.id)

    stored =
      DB.one("SELECT result FROM c2_communication_requests WHERE request_id=$1", [
        DB.uuid(p["request_id"])
      ])["result"]

    refute Map.has_key?(stored, "token")
    refute Map.has_key?(Communication.voice(a, s.id), "token")
    assert Communication.voice(a, s.id)["status"] == "connecting"

    assert {_, {:ok, _}} =
             request(s, a, "client_state", %{"lease_id" => g["lease_id"], "status" => "connected"})

    assert Communication.voice(a, s.id)["status"] == "connected"
  end

  test "control fencing, strict envelopes and expired leases cannot be resurrected", s do
    g = join_pair(s)
    a = hd(s.people)
    {p, _} = request(s, a, "heartbeat", %{"lease_id" => g["lease_id"]})

    assert {:error, "CONTROL_LOST"} =
             Communication.voice_request(a, s.id, Map.put(p, "control_epoch", 2))

    assert {:error, "INPUT_INVALID"} =
             Communication.voice_request(a, s.id, Map.put(p, "location_id", "secret"))

    DB.query("UPDATE c2_voice_leases SET expires_at=$2 WHERE id=$1", [
      DB.uuid(g["lease_id"]),
      DB.time() - 1
    ])

    assert {_, {:error, "LEASE_REVOKED"}} = request(s, a, "renew", %{"lease_id" => g["lease_id"]})
  end

  test "unknown media fence freezes a durable deterministic world plan; verified fence resumes once",
       s do
    _ = join_pair(s)
    a = hd(s.people)
    {r, m} = Communication.context!(a, s.id)
    next = put_in(r["state"], ["actors", m["role_id"], "location"], "new_scene")
    assert {:ok, :deferred} = DB.transaction(fn -> Voice.before_commit(r, next, 0, DB.time()) end)
    assert elem(Communication.context!(a, s.id), 0)["state"] == r["state"]
    Process.put(:rtc_fence_result, :unknown)
    Voice.recover(s.id)
    Store.tick(s.id)
    assert elem(Communication.context!(a, s.id), 0)["state"] == r["state"]
    assert Communication.voice(a, s.id)["status"] == "switching"
    DB.query("UPDATE c2_voice_transitions SET updated_at=0 WHERE room_id=$1", [DB.uuid(s.id)])
    Process.put(:rtc_fence_result, :fenced)
    Voice.recover(s.id)
    Store.tick(s.id)
    fresh = elem(Communication.context!(a, s.id), 0)
    assert get_in(fresh, ["state", "actors", m["role_id"], "location"]) == "new_scene"
    assert Voice.pending(fresh) == nil

    assert DB.one(
             "SELECT count(*) AS n FROM c2_voice_leases WHERE room_id=$1 AND state='closed'",
             [r["id"]]
           )["n"] == 1
  end

  test "voice reports are idempotent and unrelated targets are hidden", s do
    [a, b | _] = s.people
    target = elem(Communication.context!(b, s.id), 1)

    p = %{
      "request_id" => Util.id(),
      "target_member_id" => DB.str(target["id"]),
      "reason_code" => "noise",
      "description" => "noise"
    }

    assert {:ok, x} = Communication.report(a, s.id, p, "voice")
    assert {:ok, ^x} = Communication.report(a, s.id, p, "voice")

    assert {:error, "IDEMPOTENCY_CONFLICT"} =
             Communication.report(a, s.id, Map.put(p, "description", "other"), "voice")

    assert {:error, "TARGET_UNAVAILABLE"} =
             Communication.report(
               a,
               s.id,
               Map.merge(p, %{"request_id" => Util.id(), "target_member_id" => Util.id()}),
               "voice"
             )
  end

  test "replacement socket retires old lease and late old disconnect cannot break recovery", s do
    g = join_pair(s)
    ctx = hd(s.people)
    {r, m} = Communication.context!(ctx, s.id)

    old =
      DB.one("SELECT socket_ref FROM c2_voice_participation WHERE room_id=$1 AND member_id=$2", [
        r["id"],
        m["id"]
      ])["socket_ref"]

    connected = Map.merge(ctx, %{room: s.id, member: DB.str(m["id"])})
    fresh = Util.id()
    assert {:ok, _} = Voice.socket_connected(connected, fresh)
    assert Voice.pending(r) != nil
    assert {:ok, _} = Voice.socket_disconnected(connected, old)

    assert DB.one(
             "SELECT socket_ref FROM c2_voice_participation WHERE room_id=$1 AND member_id=$2",
             [r["id"], m["id"]]
           )["socket_ref"] == fresh

    Voice.recover(s.id)
    Store.tick(s.id)
    assert Communication.voice(ctx, s.id)["participation"] == "on"
    assert Communication.voice(ctx, s.id)["reason"] == nil
    {_p, {:ok, restored}} = request(s, ctx, "grant", %{})
    assert restored["generation"] > g["generation"]
    refute restored["lease_id"] == g["lease_id"]
  end
end
