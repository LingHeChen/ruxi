defmodule Ruxi.Repo.Migrations.HardenConstraints do
 use Ecto.Migration
 def up do
  execute "ALTER TABLE rooms ADD CONSTRAINT room_lifecycle CHECK (lifecycle IN ('lobby','running','paused','suspended','finished','abandoned'))"
  execute "ALTER TABLE room_members ADD CONSTRAINT member_seq_bounds CHECK (view_seq BETWEEN 0 AND 9007199254740991 AND replay_floor_seq BETWEEN 0 AND view_seq AND control_generation BETWEEN 1 AND 9007199254740991)"
  execute "ALTER TABLE room_items ADD CONSTRAINT item_version_bounds CHECK (version BETWEEN 1 AND 9007199254740991)"
  execute "ALTER TABLE item_offers ADD CONSTRAINT offer_state CHECK (status IN ('pending','accepted','rejected','cancelled','expired'))"
  execute """
  CREATE FUNCTION prevent_frozen_content_change() RETURNS trigger LANGUAGE plpgsql AS $$
  BEGIN
    IF OLD.status = 'published' AND
      (NEW.graph IS DISTINCT FROM OLD.graph OR NEW.content_hash IS DISTINCT FROM OLD.content_hash OR NEW.revision IS DISTINCT FROM OLD.revision OR NEW.status IS DISTINCT FROM OLD.status) THEN
      RAISE EXCEPTION 'published content is immutable';
    END IF;
    RETURN NEW;
  END $$
  """
  execute "CREATE TRIGGER immutable_content BEFORE UPDATE ON content_versions FOR EACH ROW EXECUTE FUNCTION prevent_frozen_content_change()"
 end
 def down do
  execute "DROP TRIGGER immutable_content ON content_versions"
  execute "DROP FUNCTION prevent_frozen_content_change()"
  execute "ALTER TABLE rooms DROP CONSTRAINT room_lifecycle"
  execute "ALTER TABLE room_members DROP CONSTRAINT member_seq_bounds"
  execute "ALTER TABLE room_items DROP CONSTRAINT item_version_bounds"
  execute "ALTER TABLE item_offers DROP CONSTRAINT offer_state"
 end
end
