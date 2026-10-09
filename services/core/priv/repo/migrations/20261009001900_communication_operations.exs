defmodule Ruxi.Repo.Migrations.CommunicationOperations do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE c2_rooms ADD COLUMN voice_disabled boolean NOT NULL DEFAULT false")

    execute(
      "CREATE TABLE c2_voice_operations(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),admin_id uuid NOT NULL REFERENCES users(id),request_id uuid NOT NULL,fingerprint text NOT NULL,action text NOT NULL,reason text NOT NULL,created_at bigint NOT NULL,UNIQUE(admin_id,request_id))"
    )
  end

  def down do
    execute("DROP TABLE c2_voice_operations")
    execute("ALTER TABLE c2_rooms DROP COLUMN voice_disabled")
  end
end
