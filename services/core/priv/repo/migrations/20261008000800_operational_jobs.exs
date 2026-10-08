defmodule Ruxi.Repo.Migrations.OperationalJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up(prefix: "ruxi", create_schema: false)

    execute("""
    CREATE TABLE ruxi.room_summaries (
      room_id uuid PRIMARY KEY,
      content_version_id uuid NOT NULL,
      seat_count integer NOT NULL,
      ending_code text,
      lifecycle text NOT NULL,
      started_at bigint,
      terminal_at bigint NOT NULL
    )
    """)

    execute("CREATE INDEX room_summaries_terminal ON ruxi.room_summaries(terminal_at)")
  end

  def down do
    execute("DROP TABLE ruxi.room_summaries")
    Oban.Migration.down(prefix: "ruxi")
  end
end
