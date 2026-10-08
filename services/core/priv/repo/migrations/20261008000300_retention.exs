defmodule Ruxi.Repo.Migrations.Retention do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE users ADD COLUMN status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','disabled','erased'))"
    )

    execute("ALTER TABLE rooms ADD COLUMN terminal_at bigint")
    execute("ALTER TABLE rooms ADD COLUMN bodies_purged_at bigint")

    execute(
      "ALTER TABLE account_commands ADD COLUMN created_at bigint NOT NULL DEFAULT (floor(extract(epoch from clock_timestamp())*1000)::bigint)"
    )

    execute("ALTER TABLE sessions ADD COLUMN revoked_at bigint")
    execute("UPDATE rooms SET terminal_at=updated_at WHERE lifecycle IN ('finished','abandoned')")

    execute(
      "UPDATE sessions SET revoked_at=floor(extract(epoch from clock_timestamp())*1000)::bigint WHERE revoked"
    )

    execute(
      "CREATE INDEX retention_terminal ON rooms(terminal_at) WHERE lifecycle IN ('finished','abandoned')"
    )

    execute("CREATE INDEX account_command_retention ON account_commands(created_at)")
    execute("CREATE INDEX expired_auth_cache ON auth_retry_cache(expires_at)")

    execute("""
    CREATE FUNCTION record_retention_clock() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_TABLE_NAME='rooms' THEN
        IF NEW.lifecycle IN ('finished','abandoned') AND NEW.terminal_at IS NULL THEN
          NEW.terminal_at=floor(extract(epoch from clock_timestamp())*1000)::bigint;
        END IF;
      ELSE
        IF NEW.revoked AND NEW.revoked_at IS NULL THEN
          NEW.revoked_at=floor(extract(epoch from clock_timestamp())*1000)::bigint;
        END IF;
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER room_retention_clock BEFORE INSERT OR UPDATE ON rooms FOR EACH ROW EXECUTE FUNCTION record_retention_clock()"
    )

    execute(
      "CREATE TRIGGER session_retention_clock BEFORE INSERT OR UPDATE ON sessions FOR EACH ROW EXECUTE FUNCTION record_retention_clock()"
    )
  end

  def down do
    execute("DROP TRIGGER room_retention_clock ON rooms")
    execute("DROP TRIGGER session_retention_clock ON sessions")
    execute("DROP FUNCTION record_retention_clock()")
    execute("DROP INDEX retention_terminal")
    execute("DROP INDEX account_command_retention")
    execute("DROP INDEX expired_auth_cache")
    execute("ALTER TABLE users DROP COLUMN status")
    execute("ALTER TABLE rooms DROP COLUMN terminal_at, DROP COLUMN bodies_purged_at")
    execute("ALTER TABLE account_commands DROP COLUMN created_at")
    execute("ALTER TABLE sessions DROP COLUMN revoked_at")
  end
end
