defmodule Ruxi.Accounts do
  alias Ruxi.{Auth, DB, Util}
  @iterations 600_000
  defp username!(value) do
    Util.require!(is_binary(value) and byte_size(value) <= 64, "INVALID_ARGUMENT")
    value = value |> String.trim() |> String.downcase()
    Util.require!(Regex.match?(~r/^[a-z0-9][a-z0-9_.@-]{2,63}$/, value), "INVALID_ARGUMENT")
    value
  end

  defp password!(value) do
    Util.require!(is_binary(value) and byte_size(value) in 10..128, "INVALID_ARGUMENT")
    value
  end

  defp text!(value, min, max) do
    Util.require!(
      is_binary(value) and String.length(String.trim(value)) in min..max,
      "INVALID_ARGUMENT"
    )

    String.trim(value)
  end

  defp hash(password) do
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
    "pbkdf2-sha256$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(digest)}"
  end

  defp matches?(password, encoded) do
    ["pbkdf2-sha256", rounds, salt, digest] = String.split(encoded, "$")

    actual =
      :crypto.pbkdf2_hmac(:sha256, password, Base.decode64!(salt), String.to_integer(rounds), 32)

    Plug.Crypto.secure_compare(actual, Base.decode64!(digest))
  end

  def register(p, ctx \\ nil) do
    RuxiWeb.Router.json!(p, ~w(username password display_name device_id command_id))
    name = username!(p["username"])
    password = password!(p["password"])
    display = text!(p["display_name"], 1, 24)

    Auth.retry("register", p["command_id"], p, fn ->
      DB.query("SELECT pg_advisory_xact_lock(hashtext($1))", ["username:" <> name])

      Util.require!(
        DB.one("SELECT user_id FROM player_accounts WHERE username=$1", [name]) == nil,
        "USERNAME_TAKEN"
      )

      user = if ctx, do: ctx.user, else: Util.id()
      recovery = Util.token()

      if ctx do
        Auth.valid!(ctx)
        DB.query("SELECT id FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(user)])

        Util.require!(
          DB.one("SELECT user_id FROM player_accounts WHERE user_id=$1", [DB.uuid(user)]) == nil,
          "ALREADY_REGISTERED"
        )

        DB.query("UPDATE users SET display_name=$2 WHERE id=$1", [DB.uuid(user), display])
      else
        DB.query("INSERT INTO users(id,display_name) VALUES($1,$2)", [DB.uuid(user), display])
      end

      DB.query(
        "UPDATE users SET recovery_hash=$2,recovery_generation=recovery_generation+1 WHERE id=$1",
        [DB.uuid(user), Util.hash(recovery)]
      )

      DB.query(
        "INSERT INTO player_accounts(user_id,username,password_hash,created_at) VALUES($1,$2,$3,$4)",
        [DB.uuid(user), name, hash(password), DB.time()]
      )

      Map.put(Auth.session(user, p["device_id"], "player"), "recovery_code", recovery)
    end)
  end

  def login(p, audience \\ "player") do
    RuxiWeb.Router.json!(p, ~w(username password device_id login_request_id))
    name = username!(p["username"])
    password = password!(p["password"])

    Auth.retry("account.login:" <> audience, p["login_request_id"], p, fn ->
      candidate = DB.one("SELECT user_id FROM player_accounts WHERE username=$1", [name])

      if candidate,
        do: DB.query("SELECT id FROM users WHERE id=$1 FOR UPDATE", [candidate["user_id"]])

      row =
        DB.one(
          "SELECT a.*,u.status FROM player_accounts a JOIN users u ON u.id=a.user_id WHERE username=$1 FOR UPDATE OF a",
          [name]
        )

      # An unknown username still performs the same expensive derivation.
      encoded =
        if row,
          do: row["password_hash"],
          else:
            "pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

      valid = matches?(password, encoded)
      Util.require!(row != nil and valid and row["status"] == "active", "UNAUTHORIZED")
      user = DB.str(row["user_id"])
      if audience == "admin", do: Util.require!(Auth.roles(user) != [], "NOT_ALLOWED")
      reply = Auth.session(user, p["device_id"], audience)
      if audience == "admin", do: Map.put(reply, "roles", Auth.roles(user)), else: reply
    end)
  end

  def reset_password(p) do
    RuxiWeb.Router.json!(p, ~w(recovery_code new_password device_id recovery_request_id))
    password = password!(p["new_password"])

    Util.require!(
      is_binary(p["recovery_code"]) and byte_size(p["recovery_code"]) in 20..128,
      "INVALID_ARGUMENT"
    )

    Auth.retry(
      "password.reset",
      Util.hash(p["recovery_code"]) <> p["recovery_request_id"],
      p,
      fn ->
        user =
          DB.one("SELECT id,status FROM users WHERE recovery_hash=$1 FOR UPDATE", [
            Util.hash(p["recovery_code"])
          ])

        Util.require!(user != nil and user["status"] == "active", "UNAUTHORIZED")

        account =
          DB.one("SELECT user_id FROM player_accounts WHERE user_id=$1 FOR UPDATE", [user["id"]])

        Util.require!(account != nil, "NOT_ALLOWED")
        code = Util.token()

        DB.query("UPDATE player_accounts SET password_hash=$2 WHERE user_id=$1", [
          user["id"],
          hash(password)
        ])

        DB.query(
          "UPDATE users SET recovery_hash=$2,recovery_generation=recovery_generation+1 WHERE id=$1",
          [user["id"], Util.hash(code)]
        )

        id = DB.str(user["id"])
        Auth.revoke_user(id)
        Map.put(Auth.session(id, p["device_id"], "player"), "recovery_code", code)
      end
    )
  end

  def profile(ctx) do
    Auth.valid!(ctx)

    row =
      DB.one(
        "SELECT u.id,u.display_name,a.username,a.bio,a.created_at FROM users u LEFT JOIN player_accounts a ON a.user_id=u.id WHERE u.id=$1",
        [DB.uuid(ctx.user)]
      )

    %{
      "user_id" => ctx.user,
      "display_name" => row["display_name"],
      "is_guest" => row["username"] == nil,
      "username" => row["username"],
      "bio" => row["bio"] || "",
      "created_at" => if(row["created_at"], do: Util.iso(row["created_at"]), else: nil)
    }
  end

  def update(ctx, p) do
    RuxiWeb.Router.json!(p, ~w(display_name bio command_id))
    display = text!(p["display_name"], 1, 24)
    bio = text!(p["bio"], 0, 160)

    Auth.account(ctx, "profile.update", p, fn ->
      DB.query("UPDATE users SET display_name=$2 WHERE id=$1", [DB.uuid(ctx.user), display])
      DB.query("UPDATE player_accounts SET bio=$2 WHERE user_id=$1", [DB.uuid(ctx.user), bio])
      profile(ctx)
    end)
  end

  def change_password(ctx, p) do
    RuxiWeb.Router.json!(p, ~w(current_password new_password command_id))
    old = password!(p["current_password"])
    new = password!(p["new_password"])

    Auth.account(ctx, "password.change", p, fn ->
      row =
        DB.one("SELECT password_hash FROM player_accounts WHERE user_id=$1 FOR UPDATE", [
          DB.uuid(ctx.user)
        ])

      Util.require!(row != nil and matches?(old, row["password_hash"]), "UNAUTHORIZED")

      DB.query("UPDATE player_accounts SET password_hash=$2 WHERE user_id=$1", [
        DB.uuid(ctx.user),
        hash(new)
      ])

      Auth.revoke_user(ctx.user)
      %{"changed" => true, "requires_login" => true}
    end)
  end

  def directory(ctx) do
    Auth.role!(ctx, "reviewer")

    items =
      DB.rows(
        "SELECT u.id,u.display_name,u.status,a.username,a.created_at,(SELECT count(*) FROM room_members m WHERE m.user_id=u.id) AS room_count FROM users u LEFT JOIN player_accounts a ON a.user_id=u.id ORDER BY a.created_at DESC NULLS LAST,u.id LIMIT 100"
      )
      |> Enum.map(fn row ->
        id = DB.str(row["id"])
        row |> Map.delete("id") |> Map.put("user_id", id) |> Map.put("roles", Auth.roles(id))
      end)

    %{"items" => items}
  end

  def assign_roles(ctx, id, p) do
    RuxiWeb.Router.json!(p, ~w(roles command_id))
    Auth.role!(ctx, "publisher")

    Util.require!(
      is_list(p["roles"]) and length(p["roles"]) <= 3 and
        Enum.all?(p["roles"], &(&1 in ~w(editor reviewer publisher))) and
        (id != ctx.user or "publisher" in p["roles"]),
      "INVALID_ARGUMENT"
    )

    Auth.account(ctx, "admin.roles:" <> id, p, fn ->
      user = DB.one("SELECT id,status FROM users WHERE id=$1 FOR UPDATE", [DB.uuid(id)])
      Util.require!(user != nil and user["status"] == "active", "RESOURCE_NOT_FOUND")

      Util.require!(
        DB.one("SELECT user_id FROM player_accounts WHERE user_id=$1", [user["id"]]) != nil,
        "NOT_ALLOWED"
      )

      DB.query("DELETE FROM admin_roles WHERE user_id=$1", [user["id"]])

      for role <- Enum.uniq(p["roles"]),
          do: DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,$2)", [user["id"], role])

      # Changing roles invalidates any previously issued administrator sessions.
      for session <-
            DB.rows(
              "UPDATE sessions SET revoked=true WHERE user_id=$1 AND audience='admin' RETURNING id",
              [user["id"]]
            ),
          do: Ruxi.DB.broadcast("session:#{DB.str(session["id"])}", "disconnect", %{})

      DB.query(
        "INSERT INTO audit_log(id,user_id,operation,target_id,occurred_at) VALUES($1,$2,'admin.roles',$3,$4)",
        [DB.uuid(Util.id()), DB.uuid(ctx.user), user["id"], DB.time()]
      )

      %{"roles" => Enum.uniq(p["roles"])}
    end)
  end
end
