defmodule Ruxi.Auth do
  alias Ruxi.{DB, Util, Rules, Store}

  def seal(v) do
    key = :crypto.hash(:sha256, Application.fetch_env!(:ruxi, RuxiWeb.Endpoint)[:secret_key_base])
    iv = :crypto.strong_rand_bytes(12)

    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Jason.encode!(v), "", true)

    iv <> tag <> cipher
  end

  def unseal(<<iv::binary-size(12), tag::binary-size(16), cipher::binary>>) do
    key = :crypto.hash(:sha256, Application.fetch_env!(:ruxi, RuxiWeb.Endpoint)[:secret_key_base])
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, "", tag, false) |> Jason.decode!()
  end

  def retry(scope, key, p, fun) do
    DB.transaction(fn ->
      h = Util.hash(key)
      DB.query("SELECT pg_advisory_xact_lock(hashtext($1))", [scope <> h])
      row = DB.one("SELECT * FROM auth_retry_cache WHERE scope=$1 AND key_hash=$2", [scope, h])
      now = DB.time()

      if row && row["expires_at"] > now do
        Util.require!(row["request_hash"] == Util.hash(p), "IDEMPOTENCY_CONFLICT")
        reply = unseal(row["response_ciphertext"])
        if reply["user_id"], do: active!(reply["user_id"])
        reply
      else
        reply = fun.()

        DB.query(
          "INSERT INTO auth_retry_cache(scope,key_hash,request_hash,response_ciphertext,expires_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(scope,key_hash) DO UPDATE SET request_hash=$3,response_ciphertext=$4,expires_at=$5",
          [scope, h, Util.hash(p), seal(reply), now + 60_000]
        )

        reply
      end
    end)
  end

  def session(user, device, audience, absolute \\ nil) do
    active!(user)
    now = DB.time()
    a = Util.token()
    r = Util.token()
    sid = Util.id()
    absolute = absolute || now + if(audience == "admin", do: 28_800_000, else: 2_592_000_000)

    DB.query(
      "INSERT INTO sessions(id,user_id,access_hash,refresh_hash,device_id,audience,expires_at,family_expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
      [
        DB.uuid(sid),
        DB.uuid(user),
        Util.hash(a),
        Util.hash(r),
        DB.uuid(device),
        audience,
        min(now + 900_000, absolute),
        absolute
      ]
    )

    %{
      "user_id" => user,
      "access_token" => a,
      "refresh_token" => r,
      "expires_at" => Util.iso(min(now + 900_000, absolute))
    }
  end

  def guest(p) do
    retry("guest", p["command_id"], p, fn ->
      u = Util.id()
      recovery = Util.token()

      DB.query("INSERT INTO users(id,display_name,recovery_hash) VALUES($1,'游客',$2)", [
        DB.uuid(u),
        Util.hash(recovery)
      ])

      Map.put(session(u, p["device_id"], "player"), "recovery_code", recovery)
    end)
  end

  def recover(p) do
    retry("recover", Util.hash(p["recovery_code"]) <> p["recovery_request_id"], p, fn ->
      row =
        DB.one("SELECT * FROM users WHERE recovery_hash=$1 FOR UPDATE", [
          Util.hash(p["recovery_code"])
        ])

      Util.require!(row != nil and row["status"] == "active", "UNAUTHORIZED")
      user = DB.str(row["id"])
      code = Util.token()

      DB.query(
        "UPDATE users SET recovery_hash=$2,recovery_generation=recovery_generation+1 WHERE id=$1",
        [row["id"], Util.hash(code)]
      )

      revoke_user(user)
      Map.put(session(user, p["device_id"], "player"), "recovery_code", code)
    end)
  end

  def authenticate(token, audience \\ "player") do
    row =
      DB.one(
        "SELECT s.*,u.display_name,u.status AS user_status FROM sessions s JOIN users u ON u.id=s.user_id WHERE access_hash=$1",
        [Util.hash(token || "")]
      )

    Util.require!(
      row != nil and not row["revoked"] and row["expires_at"] > Util.now(),
      "UNAUTHORIZED"
    )

    Util.require!(row["audience"] == audience, "NOT_ALLOWED")
    Util.require!(row["user_status"] == "active", "UNAUTHORIZED")

    %{
      user: DB.str(row["user_id"]),
      session: DB.str(row["id"]),
      device: DB.str(row["device_id"]),
      expires: row["expires_at"],
      audience: audience
    }
  end

  def valid!(ctx),
    do:
      Util.require!(
        DB.one(
          "SELECT s.id FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=$1 AND NOT s.revoked AND s.expires_at>$2 AND u.status='active'",
          [
            DB.uuid(ctx.session),
            Util.now()
          ]
        ) != nil,
        "AUTH_EXPIRED"
      )

  def active!(user),
    do:
      Util.require!(
        DB.one("SELECT id FROM users WHERE id=$1 AND status='active'", [DB.uuid(user)]) != nil,
        "UNAUTHORIZED"
      )

  def refresh(p, audience) do
    retry("refresh", Util.hash(p["refresh_token"]) <> p["refresh_request_id"], p, fn ->
      row =
        DB.one("SELECT * FROM sessions WHERE refresh_hash=$1 FOR UPDATE", [
          Util.hash(p["refresh_token"])
        ])

      if row == nil do
        consumed =
          DB.one("SELECT session_id FROM consumed_refresh WHERE token_hash=$1", [
            Util.hash(p["refresh_token"])
          ])

        if consumed,
          do: DB.query("UPDATE sessions SET revoked=true WHERE id=$1", [consumed["session_id"]])

        # Commit revocation, then return an error marker outside this transaction.
        %{"auth_error" => "UNAUTHORIZED"}
      else
        Util.require!(
          !row["revoked"] and row["family_expires_at"] > DB.time() and row["audience"] == audience and
            DB.str(row["device_id"]) == p["device_id"],
          "UNAUTHORIZED"
        )

        active!(DB.str(row["user_id"]))

        a = Util.token()
        r = Util.token()
        exp = min(DB.time() + 900_000, row["family_expires_at"])

        DB.query("INSERT INTO consumed_refresh(token_hash,session_id) VALUES($1,$2)", [
          row["refresh_hash"],
          row["id"]
        ])

        DB.query("UPDATE sessions SET access_hash=$2,refresh_hash=$3,expires_at=$4 WHERE id=$1", [
          row["id"],
          Util.hash(a),
          Util.hash(r),
          exp
        ])

        %{
          "user_id" => DB.str(row["user_id"]),
          "access_token" => a,
          "refresh_token" => r,
          "expires_at" => Util.iso(exp)
        }
      end
    end)
  end

  def logout(ctx) do
    DB.query("UPDATE sessions SET revoked=true WHERE id=$1", [DB.uuid(ctx.session)])
    RuxiWeb.Endpoint.broadcast("session:#{ctx.session}", "disconnect", %{})
    %{"revoked" => true}
  end

  def revoke_user(user) do
    for row <-
          DB.rows("UPDATE sessions SET revoked=true WHERE user_id=$1 RETURNING id", [
            DB.uuid(user)
          ]),
        do: RuxiWeb.Endpoint.broadcast("session:#{DB.str(row["id"])}", "disconnect", %{})
  end

  def account(ctx, operation, p, fun) do
    result =
      DB.transaction(fn ->
        valid!(ctx)
        Util.require!(Ruxi.Contract.uuid?(p["command_id"]), "INVALID_ARGUMENT")
        DB.query("SELECT id FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(ctx.user)])
        valid!(ctx)

        if operation in ["invite.rotate", "chat.report"],
          do: Store.auth!(Store.load!(p["room_id"], true)["state_json"], ctx)

        r =
          DB.one(
            "SELECT * FROM account_commands WHERE user_id=$1 AND operation=$2 AND command_id=$3",
            [DB.uuid(ctx.user), operation, DB.uuid(p["command_id"])]
          )

        if r do
          Util.require!(r["payload_hash"] == Util.hash(p), "IDEMPOTENCY_CONFLICT")

          if r["response_json"]["sealed"],
            do: unseal(Base.decode64!(r["response_json"]["sealed"])),
            else: r["response_json"]
        else
          DB.query("SAVEPOINT account_effect")

          reply =
            try do
              fun.()
            catch
              {:error, code} ->
                DB.query("ROLLBACK TO SAVEPOINT account_effect")
                %{"account_error" => code}
            end

          DB.query("RELEASE SAVEPOINT account_effect")
          stored = %{"sealed" => Base.encode64(seal(reply))}

          DB.query(
            "INSERT INTO account_commands(user_id,operation,command_id,payload_hash,response_json) VALUES($1,$2,$3,$4,$5)",
            [DB.uuid(ctx.user), operation, DB.uuid(p["command_id"]), Util.hash(p), stored]
          )

          reply
        end
      end)

    case result do
      {:ok, %{"account_error" => code}} -> {:error, code}
      other -> other
    end
  end

  def create_room(ctx, p) do
    account(ctx, "room.create", p, fn ->
      story =
        DB.one(
          "SELECT s.*,v.availability,v.graph FROM stories s JOIN content_versions v ON v.id=s.current_version_id WHERE s.id=$1",
          [DB.uuid(p["story_id"])]
        )

      Util.require!(story && story["availability"] == "available", "RESOURCE_NOT_FOUND")
      rid = Util.id()
      mid = Util.id()
      now = DB.time()
      ver = DB.str(story["current_version_id"])
      invite = invite_code()

      s =
        Rules.initial(rid, ver, mid, now, story["graph"])
        |> Rules.add_member(mid, ctx.user, now)
        |> Map.merge(%{
          "invite" => invite,
          "invite_expires" => now + 86_400_000,
          "story_id" => p["story_id"]
        })

      DB.query(
        "INSERT INTO rooms(id,content_version_id,state_json,lifecycle,deadline_at,updated_at) VALUES($1,$2,$3,'lobby',$4,$5)",
        [DB.uuid(rid), story["current_version_id"], s, s["deadline"], now]
      )

      DB.query("INSERT INTO room_members(id,room_id,user_id) VALUES($1,$2,$3)", [
        DB.uuid(mid),
        DB.uuid(rid),
        DB.uuid(ctx.user)
      ])

      %{
        "room_id" => rid,
        "membership_id" => mid,
        "content_version_id" => ver,
        "seat_count" => story["graph"]["seat_count"],
        "invite_code" => invite,
        "invite_expires_at" => Util.iso(s["invite_expires"])
      }
    end)
  end

  def invite_code do
    alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" |> String.graphemes()

    :crypto.strong_rand_bytes(8)
    |> :binary.bin_to_list()
    |> Enum.map_join(&Enum.at(alphabet, rem(&1, length(alphabet))))
  end

  def join_room(ctx, p) do
    account(ctx, "room.join", p, fn ->
      row =
        DB.one("SELECT * FROM rooms WHERE state_json->>'invite'=$1 FOR UPDATE", [p["invite_code"]])

      Util.require!(row != nil, "INVITE_UNAVAILABLE")
      s = row["state_json"]
      now = DB.time()
      existing = Enum.find(s["members"], &(&1["user_id"] == ctx.user))

      Util.require!(
        s["lifecycle"] == "lobby" and s["invite_expires"] > now and
          (existing || length(s["members"]) < Ruxi.Content.graph(s)["seat_count"]),
        "INVITE_UNAVAILABLE"
      )

      mid = if existing, do: existing["id"], else: Util.id()

      if !existing do
        DB.query("INSERT INTO room_members(id,room_id,user_id) VALUES($1,$2,$3)", [
          DB.uuid(mid),
          row["id"],
          DB.uuid(ctx.user)
        ])

        Store.save(s, Rules.add_member(s, mid, ctx.user, now), "member_changed", now)
      end

      %{
        "room_id" => s["room_id"],
        "membership_id" => mid,
        "content_version_id" => s["content_version_id"],
        "seat_count" => Ruxi.Content.graph(s)["seat_count"]
      }
    end)
  end

  def member_context(ctx, rid, device, generation) do
    m =
      DB.one("SELECT id FROM room_members WHERE room_id=$1 AND user_id=$2", [
        DB.uuid(rid),
        DB.uuid(ctx.user)
      ])

    Util.require!(m != nil, "RESOURCE_NOT_FOUND")
    Map.merge(ctx, %{room: rid, member: DB.str(m["id"]), device: device, generation: generation})
  end

  def ticket(ctx, rid, p) do
    fun = fn ->
      row = Store.load!(rid, true)
      s = row["state_json"]
      m = Enum.find(s["members"], &(&1["user_id"] == ctx.user))
      Util.require!(m != nil, "RESOURCE_NOT_FOUND")
      device = p["device_id"]
      other = m["device"] && m["device"] != device
      Util.require!(!other or p["takeover"] == true, "CONTROL_CONFIRMATION_REQUIRED")
      gen = m["generation"] + if(other, do: 1, else: 0)

      n =
        Rules.update_member(
          s,
          m["id"],
          &Map.merge(&1, %{"device" => device, "generation" => gen})
        )

      if n != s, do: Store.save(s, n, "member_changed", DB.time())
      token = Util.token()
      exp = DB.time() + 60_000

      DB.query(
        "INSERT INTO socket_tickets(token_hash,session_id,room_id,member_id,device_id,generation,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
        [
          Util.hash(token),
          DB.uuid(ctx.session),
          DB.uuid(rid),
          DB.uuid(m["id"]),
          DB.uuid(device),
          gen,
          exp
        ]
      )

      %{
        "socket_ticket" => token,
        "expires_at" => Util.iso(exp),
        "membership_id" => m["id"],
        "control_generation" => gen,
        "recovery_epoch" => Util.epoch()
      }
    end

    if p["takeover"] == true,
      do: account(ctx, "room.takeover", Map.put(p, "room_id", rid), fun),
      else: DB.transaction(fun)
  end

  def consume_ticket(token) do
    DB.transaction(fn ->
      r =
        DB.one(
          "UPDATE socket_tickets SET consumed=true WHERE token_hash=$1 AND NOT consumed AND expires_at>$2 RETURNING *",
          [Util.hash(token), DB.time()]
        )

      Util.require!(r != nil, "UNAUTHORIZED")

      session =
        DB.one("SELECT * FROM sessions WHERE id=$1 AND NOT revoked AND expires_at>$2", [
          r["session_id"],
          DB.time()
        ])

      Util.require!(session != nil, "UNAUTHORIZED")
      active!(DB.str(session["user_id"]))

      ctx = %{
        room: DB.str(r["room_id"]),
        member: DB.str(r["member_id"]),
        device: DB.str(r["device_id"]),
        generation: r["generation"],
        user: DB.str(session["user_id"]),
        session: DB.str(session["id"]),
        expires: session["expires_at"]
      }

      Store.auth!(Store.load!(ctx.room)["state_json"], ctx)
      ctx
    end)
  end

  def admin_exchange(p) do
    retry("admin.exchange", Util.hash(p["login_code"]) <> p["login_request_id"], p, fn ->
      row =
        DB.one(
          "UPDATE admin_login_codes SET consumed_at=$2 WHERE token_hash=$1 AND consumed_at IS NULL AND expires_at>$2 RETURNING user_id",
          [Util.hash(p["login_code"]), DB.time()]
        )

      Util.require!(row != nil, "UNAUTHORIZED")
      u = DB.str(row["user_id"])
      Map.put(session(u, p["device_id"], "admin"), "roles", roles(u))
    end)
  end

  def roles(u),
    do:
      DB.rows("SELECT role FROM admin_roles WHERE user_id=$1", [DB.uuid(u)])
      |> Enum.map(& &1["role"])

  def role!(ctx, role), do: Util.require!(role in roles(ctx.user), "NOT_ALLOWED")
end
