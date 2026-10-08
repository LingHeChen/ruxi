alias Ruxi.{DB, Util}
user = System.fetch_env!("DRILL_ERASED_USER")
# Run on an isolated restored database before enabling the public Endpoint.
DB.transaction(fn ->
  DB.query("UPDATE sessions SET revoked=true,revoked_at=$1", [DB.time()])
  DB.query("DELETE FROM socket_tickets")
  DB.query("DELETE FROM consumed_refresh")
  DB.query("DELETE FROM auth_retry_cache")
  DB.query("DELETE FROM work_claims")
  DB.query("UPDATE work_items SET status='queued',lease_hash=NULL,lease_until=NULL,leased_by=NULL WHERE status='leased'")
  DB.query("UPDATE rooms SET owner_instance=NULL,lease_until=0,owner_epoch=owner_epoch+1")
end)
row = DB.one("SELECT status,recovery_hash FROM users WHERE id=$1", [DB.uuid(user)])
if row != %{"status" => "erased", "recovery_hash" => nil}, do: raise("erasure ledger was not applied")
if DB.one("SELECT count(*) AS n FROM sessions WHERE NOT revoked")["n"] != 0, do: raise("restored sessions remain valid")
if DB.one("SELECT count(*) AS n FROM socket_tickets")["n"] != 0, do: raise("restored socket tickets remain valid")
if DB.one("SELECT count(*) AS n FROM rooms WHERE owner_instance IS NOT NULL")["n"] != 0, do: raise("restored room ownership remains valid")
IO.puts(Jason.encode!(%{"verified" => true, "recovery_epoch" => Util.epoch(), "erasure_applied" => true, "sessions_revoked" => true, "owners_fenced" => true}))
