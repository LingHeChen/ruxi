defmodule Ruxi.Repo.Migrations.C2Favorites do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TABLE c2_favorites(user_id uuid NOT NULL REFERENCES users(id),project_id uuid NOT NULL REFERENCES c2_projects(id),created_at bigint NOT NULL,PRIMARY KEY(user_id,project_id))",
      "DROP TABLE c2_favorites"
    )
  end
end
