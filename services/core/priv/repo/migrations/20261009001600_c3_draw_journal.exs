defmodule Ruxi.Repo.Migrations.C3DrawJournal do
  use Ecto.Migration
  def change do
    # No FK: journaling on a second connection must not wait on the locked world row.
    execute("CREATE TABLE c3_resolution_draws(room_id uuid NOT NULL,step_id uuid NOT NULL,intent_id uuid NOT NULL,draw_slot integer NOT NULL,roll integer NOT NULL CHECK(roll BETWEEN 1 AND 100),algorithm_version text NOT NULL,owner_epoch bigint NOT NULL,created_at bigint NOT NULL,abandoned boolean NOT NULL DEFAULT false,PRIMARY KEY(room_id,step_id,intent_id,draw_slot))", "DROP TABLE c3_resolution_draws")
    execute("CREATE INDEX c3_draw_retention ON c3_resolution_draws(created_at)", "DROP INDEX c3_draw_retention")
  end
end
