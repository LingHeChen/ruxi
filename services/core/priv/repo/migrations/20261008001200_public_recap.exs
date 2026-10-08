defmodule Ruxi.Repo.Migrations.PublicRecap do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TABLE room_public_events(room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,seq bigint NOT NULL CHECK(seq>0),kind text NOT NULL CHECK(kind IN ('phase','lifecycle','shared_clue')),label text NOT NULL CHECK(length(label) BETWEEN 1 AND 500),occurred_at bigint NOT NULL,PRIMARY KEY(room_id,seq))"
    )
  end

  def down, do: execute("DROP TABLE room_public_events")
end
