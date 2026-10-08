defmodule Ruxi.Repo.Migrations.AccountsCatalog do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TABLE player_accounts (user_id uuid PRIMARY KEY REFERENCES users(id),username text UNIQUE NOT NULL,password_hash text NOT NULL,bio text NOT NULL DEFAULT '',created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE story_favorites (user_id uuid REFERENCES users(id),story_id uuid REFERENCES stories(id),created_at bigint NOT NULL,PRIMARY KEY(user_id,story_id))"
    )

    execute("CREATE INDEX story_favorites_story_idx ON story_favorites(story_id)")

    execute(
      "ALTER TABLE stories ADD COLUMN category text NOT NULL DEFAULT 'mystery' CHECK(category IN ('mystery','emotion','scifi','adventure')), ADD COLUMN difficulty text NOT NULL DEFAULT 'beginner' CHECK(difficulty IN ('beginner','intermediate','advanced'))"
    )
  end

  def down do
    execute("DROP TABLE story_favorites")
    execute("DROP TABLE player_accounts")
    execute("ALTER TABLE stories DROP COLUMN category, DROP COLUMN difficulty")
  end
end
