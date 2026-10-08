alias Ruxi.{DB, Util}

if Process.whereis(Ruxi.Supervisor),
  do:
    raise(
      "Run this administration command with mix run --no-start; it must not start a second Core dispatcher"
    )

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Ruxi.Repo.start_link()
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
