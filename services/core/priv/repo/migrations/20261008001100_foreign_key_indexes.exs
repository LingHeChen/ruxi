defmodule Ruxi.Repo.Migrations.ForeignKeyIndexes do
  use Ecto.Migration

  def up do
    execute("CREATE INDEX outbox_event_reference ON ruxi.outbox(room_id,member_id,seq)")
    execute("CREATE INDEX work_room_reference ON ruxi.work_items(room_id)")
    execute("CREATE INDEX ticket_session_reference ON ruxi.socket_tickets(session_id)")
    execute("CREATE INDEX report_room_reference ON ruxi.chat_reports(room_id)")
  end

  def down do
    for index <-
          ~w(outbox_event_reference work_room_reference ticket_session_reference report_room_reference),
        do: execute("DROP INDEX ruxi.#{index}")
  end
end
