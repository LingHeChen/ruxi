defmodule Ruxi.Repo.Migrations.ObjectRetention do
  use Ecto.Migration

  def change do
    alter table(:work_items, prefix: "ruxi") do
      add(:objects_purged_at, :bigint)
    end
  end
end
