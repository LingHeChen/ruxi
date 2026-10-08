defmodule Ruxi.Repo.Migrations.FrozenElectorate do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE ruxi.vote_rounds ADD COLUMN electorate_frozen boolean NOT NULL DEFAULT false"
    )

    execute("""
    CREATE TABLE ruxi.vote_electorate (
      room_id uuid NOT NULL, round_id uuid NOT NULL, member_id uuid NOT NULL,
      PRIMARY KEY(room_id,round_id,member_id),
      FOREIGN KEY(room_id,round_id) REFERENCES ruxi.vote_rounds(room_id,id) ON DELETE CASCADE,
      FOREIGN KEY(room_id,member_id) REFERENCES ruxi.room_members(room_id,id)
    )
    """)

    execute(
      "INSERT INTO ruxi.vote_electorate SELECT r.room_id,r.id,m.id FROM ruxi.vote_rounds r JOIN ruxi.room_members m ON m.room_id=r.room_id WHERE m.role_code IS NOT NULL"
    )

    execute(
      "INSERT INTO ruxi.vote_electorate SELECT room_id,round_id,member_id FROM ruxi.votes ON CONFLICT DO NOTHING"
    )

    execute(
      "ALTER TABLE ruxi.votes ADD CONSTRAINT votes_frozen_member_fk FOREIGN KEY(room_id,round_id,member_id) REFERENCES ruxi.vote_electorate(room_id,round_id,member_id)"
    )

    execute("UPDATE ruxi.vote_rounds SET electorate_frozen=true")

    execute("""
    CREATE FUNCTION ruxi.guard_electorate() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE frozen boolean;
    BEGIN
      IF TG_OP='DELETE' THEN
        SELECT electorate_frozen INTO frozen FROM ruxi.vote_rounds WHERE room_id=OLD.room_id AND id=OLD.round_id;
      ELSE
        SELECT electorate_frozen INTO frozen FROM ruxi.vote_rounds WHERE room_id=NEW.room_id AND id=NEW.round_id;
      END IF;
      IF frozen THEN RAISE EXCEPTION 'electorate is frozen'; END IF;
      IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END $$;
    """)

    execute(
      "CREATE TRIGGER electorate_immutable BEFORE INSERT OR UPDATE OR DELETE ON ruxi.vote_electorate FOR EACH ROW EXECUTE FUNCTION ruxi.guard_electorate()"
    )
  end

  def down do
    execute("ALTER TABLE ruxi.votes DROP CONSTRAINT votes_frozen_member_fk")
    execute("DROP TABLE ruxi.vote_electorate")
    execute("DROP FUNCTION ruxi.guard_electorate()")
    execute("ALTER TABLE ruxi.vote_rounds DROP COLUMN electorate_frozen")
  end
end
