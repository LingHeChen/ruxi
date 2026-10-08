defmodule Ruxi.Repo.Migrations.Telemetry do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE telemetry_events (
      event_id uuid PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES users(id),
      session_id uuid NOT NULL,
      event_name text NOT NULL,
      schema_version integer NOT NULL CHECK(schema_version=1),
      app_version text NOT NULL,
      occurred_at timestamptz NOT NULL,
      received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      properties jsonb NOT NULL
    )
    """)

    execute("CREATE INDEX telemetry_retention_idx ON telemetry_events(received_at)")
    execute("CREATE INDEX telemetry_user_idx ON telemetry_events(user_id)")
  end

  def down, do: execute("DROP TABLE telemetry_events")
end
