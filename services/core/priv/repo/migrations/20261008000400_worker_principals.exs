defmodule Ruxi.Repo.Migrations.WorkerPrincipals do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE work_items ADD COLUMN leased_by text")

    execute(
      "UPDATE rooms SET state_json=jsonb_set(state_json,'{terminal_at}',to_jsonb(terminal_at),true) WHERE terminal_at IS NOT NULL"
    )
  end

  def down do
    execute("ALTER TABLE work_items DROP COLUMN leased_by")
  end
end
