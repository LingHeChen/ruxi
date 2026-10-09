defmodule Ruxi.Repo.Migrations.VoiceSocketPresence do
  use Ecto.Migration
  def up, do: execute("ALTER TABLE c2_voice_participation ADD COLUMN socket_ref text")
  def down, do: execute("ALTER TABLE c2_voice_participation DROP COLUMN socket_ref")
end
