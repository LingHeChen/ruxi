alias Ruxi.{DB, Util}
alias Ruxi.C3.Draws

source =
  DB.one(
    "SELECT * FROM c2_rooms WHERE state->>'engine_version'='3' ORDER BY created_at DESC LIMIT 1"
  )

Util.require!(source != nil, "FIXTURE_REQUIRED")
rid = Util.id()
step = Util.id()
intent = Util.id()
now = DB.time()

state =
  source["state"]
  |> Map.merge(%{"status" => "suspended", "suspended_at" => now, "step_id" => step})

DB.query(
  "INSERT INTO c2_rooms(id,release_id,host_user_id,status,state,owner_epoch,updated_at,created_at) VALUES($1,$2,$3,'suspended',$4,0,$5,$5)",
  [DB.uuid(rid), source["release_id"], source["host_user_id"], state, now]
)

{:error, "FAULT_AFTER_DRAW"} =
  DB.transaction(fn ->
    r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [DB.uuid(rid)])
    DB.query("UPDATE c2_rooms SET owner_epoch=owner_epoch+1 WHERE id=$1", [r["id"]])
    Draws.with_room(r, fn -> Draws.draw(state, intent) end)
    Util.fail("FAULT_AFTER_DRAW")
  end)

row =
  DB.one(
    "SELECT roll FROM c3_resolution_draws WHERE room_id=$1 AND step_id=$2 AND intent_id=$3",
    [DB.uuid(rid), DB.uuid(step), DB.uuid(intent)]
  )

Util.require!(row != nil, "JOURNAL_ROLLED_BACK")

{:ok, roll} =
  DB.transaction(fn ->
    r = DB.one("SELECT * FROM c2_rooms WHERE id=$1 FOR UPDATE", [DB.uuid(rid)])
    DB.query("UPDATE c2_rooms SET owner_epoch=owner_epoch+1 WHERE id=$1", [r["id"]])
    Draws.with_room(r, fn -> Draws.draw(state, intent) end)
  end)

Util.require!(row["roll"] == roll, "DRAW_CHANGED")

Util.require!(
  DB.one("SELECT state FROM c2_rooms WHERE id=$1", [DB.uuid(rid)])["state"] == state,
  "WORLD_CHANGED"
)

DB.query("UPDATE c3_resolution_draws SET abandoned=true WHERE room_id=$1", [DB.uuid(rid)])

IO.puts(
  Jason.encode!(%{
    passed: true,
    room_id: rid,
    checks: [
      "draw-survives-world-rollback",
      "recovery-replays-same-draw",
      "world-remains-unchanged"
    ],
    algorithm: "crypto-rejection-v1"
  })
)
