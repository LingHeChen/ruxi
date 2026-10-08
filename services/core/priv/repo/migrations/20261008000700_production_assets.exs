defmodule Ruxi.Repo.Migrations.ProductionAssets do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE assets (
      id uuid PRIMARY KEY, created_by uuid REFERENCES users(id),
      filename text NOT NULL, mime_type text NOT NULL,
      size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 524288000),
      sha256 text NOT NULL, object_key text NOT NULL UNIQUE,
      status text NOT NULL CHECK(status IN ('uploading','uploaded','processing','ready','quarantined')),
      upload_expires_at bigint NOT NULL, created_at bigint NOT NULL,
      duration_ms bigint, outputs jsonb, error_code text,
      rights_source text NOT NULL DEFAULT ''
    )
    """)

    execute("ALTER TABLE work_items ADD COLUMN created_by uuid REFERENCES users(id)")
    execute("CREATE INDEX work_ready_idx ON work_items(kind,status,created_at)")
    execute("CREATE INDEX assets_creator_idx ON assets(created_by,created_at)")
  end

  def down do
    execute("ALTER TABLE work_items DROP COLUMN created_by")
    execute("DROP TABLE assets")
  end
end
