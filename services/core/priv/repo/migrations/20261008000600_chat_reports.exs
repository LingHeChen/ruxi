defmodule Ruxi.Repo.Migrations.ChatReports do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE chat_reports (
      id uuid PRIMARY KEY,
      room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
      reporter_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
      sender_member_id uuid,
      message_id uuid NOT NULL,
      message_text text,
      reason text NOT NULL CHECK(reason IN ('harassment','privacy','spam','other')),
      status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','dismissed')),
      created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      reviewed_at timestamptz,
      FOREIGN KEY(room_id,sender_member_id) REFERENCES room_members(room_id,id) ON DELETE CASCADE
    )
    """)

    execute("CREATE INDEX chat_report_queue_idx ON chat_reports(status,created_at)")

    execute(
      "CREATE UNIQUE INDEX chat_report_dedup_idx ON chat_reports(reporter_user_id,room_id,message_id)"
    )
  end

  def down, do: execute("DROP TABLE chat_reports")
end
