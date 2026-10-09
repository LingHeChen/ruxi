defmodule Ruxi.Repo.Migrations.VoiceBudget do
  use Ecto.Migration

  def up do
    execute("CREATE TABLE c2_voice_budget_days(day date PRIMARY KEY,reached_at bigint)")

    execute(
      "CREATE TABLE c2_voice_daily_usage(day date PRIMARY KEY,estimated_ms bigint NOT NULL DEFAULT 0)"
    )
  end

  def down do
    execute("DROP TABLE c2_voice_daily_usage")
    execute("DROP TABLE c2_voice_budget_days")
  end
end
