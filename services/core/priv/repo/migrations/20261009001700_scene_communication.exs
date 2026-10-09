defmodule Ruxi.Repo.Migrations.SceneCommunication do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TABLE c2_chat_messages(id uuid PRIMARY KEY,room_id uuid NOT NULL,sender_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,scope text NOT NULL CHECK(scope IN ('global','scene','faction')),body text NOT NULL CHECK(char_length(body) BETWEEN 1 AND 1000),created_at bigint NOT NULL,UNIQUE(room_id,sender_id,request_id),FOREIGN KEY(room_id,sender_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_chat_recipients(room_id uuid NOT NULL,message_id uuid REFERENCES c2_chat_messages(id) ON DELETE CASCADE,member_id uuid NOT NULL,PRIMARY KEY(message_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute("CREATE INDEX c2_chat_history ON c2_chat_recipients(room_id,member_id)")

    execute(
      "CREATE TABLE c2_voice_participation(room_id uuid NOT NULL,member_id uuid NOT NULL,enabled boolean NOT NULL DEFAULT false,revision bigint NOT NULL DEFAULT 0,device_id uuid NOT NULL,control_epoch bigint NOT NULL,restricted boolean NOT NULL DEFAULT false,PRIMARY KEY(room_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_communication_requests(room_id uuid NOT NULL,member_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,result jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,request_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_communication_reports(id uuid PRIMARY KEY,room_id uuid NOT NULL,reporter_id uuid NOT NULL,target_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,kind text NOT NULL,reason text NOT NULL,description text NOT NULL,created_at bigint NOT NULL,UNIQUE(room_id,reporter_id,request_id),FOREIGN KEY(room_id,reporter_id) REFERENCES c2_room_members(room_id,id),FOREIGN KEY(room_id,target_id) REFERENCES c2_room_members(room_id,id))"
    )
  end

  def down do
    for table <-
          ~w(c2_communication_reports c2_communication_requests c2_voice_participation c2_chat_recipients c2_chat_messages),
        do: execute("DROP TABLE #{table}")
  end
end
