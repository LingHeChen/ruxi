defmodule Ruxi.Repo.Migrations.VoiceTargetedRevocation do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE c2_voice_channels ADD COLUMN ban_accepted_at bigint")

    execute("""
    CREATE TABLE c2_voice_revocations (
      id uuid PRIMARY KEY, room_id uuid NOT NULL REFERENCES c2_rooms(id) ON DELETE CASCADE,
      member_id uuid NOT NULL, channel_id uuid NOT NULL REFERENCES c2_voice_channels(id) ON DELETE CASCADE,
      rtc_uid text NOT NULL, token_expires_at bigint NOT NULL,
      phase text NOT NULL DEFAULT 'pending', accepted_at bigint, created_at bigint NOT NULL,
      UNIQUE(channel_id,rtc_uid),
      FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id) ON DELETE CASCADE
    )
    """)

    execute(
      "CREATE INDEX c2_voice_revocations_pending ON c2_voice_revocations(room_id) WHERE phase='pending'"
    )
  end

  def down do
    execute("DROP TABLE c2_voice_revocations")
    execute("ALTER TABLE c2_voice_channels DROP COLUMN ban_accepted_at")
  end
end
