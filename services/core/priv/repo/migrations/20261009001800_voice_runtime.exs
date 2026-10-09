defmodule Ruxi.Repo.Migrations.VoiceRuntime do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE c2_rooms ADD COLUMN voice_revision bigint NOT NULL DEFAULT 0")

    execute(
      "CREATE TABLE c2_voice_channels(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),scene_id text NOT NULL,generation bigint NOT NULL,rtc_room_id text NOT NULL UNIQUE,status text NOT NULL,roster jsonb NOT NULL,max_token_expires_at bigint NOT NULL DEFAULT 0,UNIQUE(room_id,scene_id,generation))"
    )

    execute(
      "CREATE UNIQUE INDEX c2_voice_current ON c2_voice_channels(room_id,scene_id) WHERE status IN ('active','opening')"
    )

    execute(
      "CREATE TABLE c2_voice_leases(id uuid PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,channel_id uuid NOT NULL REFERENCES c2_voice_channels(id),device_id uuid NOT NULL,control_epoch bigint NOT NULL,rtc_uid text NOT NULL,state text NOT NULL,expires_at bigint NOT NULL,token_expires_at bigint NOT NULL,created_at bigint NOT NULL,last_seen_at bigint NOT NULL,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE UNIQUE INDEX c2_voice_active_lease ON c2_voice_leases(room_id,member_id) WHERE state IN ('issued','connected')"
    )

    execute(
      "CREATE TABLE c2_voice_transitions(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),owner_epoch bigint NOT NULL,base_revision bigint NOT NULL,proposed_state jsonb,channel_ids uuid[] NOT NULL,phase text NOT NULL,attempts integer NOT NULL DEFAULT 0,created_at bigint NOT NULL,updated_at bigint NOT NULL)"
    )

    execute(
      "CREATE UNIQUE INDEX c2_voice_pending ON c2_voice_transitions(room_id) WHERE phase IN ('retiring','blocked','fenced')"
    )

    execute(
      "CREATE TABLE c2_voice_usage(lease_id uuid PRIMARY KEY REFERENCES c2_voice_leases(id),room_id uuid NOT NULL REFERENCES c2_rooms(id),joined_at bigint NOT NULL,left_at bigint,confidence text NOT NULL DEFAULT 'estimated')"
    )
  end

  def down do
    execute("ALTER TABLE c2_rooms DROP COLUMN voice_revision")

    for t <- ~w(c2_voice_usage c2_voice_transitions c2_voice_leases c2_voice_channels),
        do: execute("DROP TABLE #{t}")
  end
end
