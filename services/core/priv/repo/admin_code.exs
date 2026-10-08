alias Ruxi.{DB, Util}
[user_id | roles] = System.argv()
roles = if roles == [], do: ~w(editor reviewer publisher), else: roles
Util.require!(Enum.all?(roles, &(&1 in ~w(editor reviewer publisher))), "INVALID_ARGUMENT")

DB.transaction(fn ->
  DB.query("INSERT INTO users(id,display_name) VALUES($1,'内容管理员') ON CONFLICT DO NOTHING", [
    DB.uuid(user_id)
  ])

  for role <- roles,
      do:
        DB.query("INSERT INTO admin_roles(user_id,role) VALUES($1,$2) ON CONFLICT DO NOTHING", [
          DB.uuid(user_id),
          role
        ])

  code = Util.token()

  DB.query(
    "INSERT INTO admin_login_codes(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)",
    [DB.uuid(Util.id()), DB.uuid(user_id), Util.hash(code), DB.time() + 300_000]
  )

  IO.puts("One-time admin code (expires in 5 minutes): " <> code)
end)
