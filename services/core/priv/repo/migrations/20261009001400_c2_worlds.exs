defmodule Ruxi.Repo.Migrations.C2Worlds do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TABLE c2_projects(id uuid PRIMARY KEY,owner_id uuid NOT NULL REFERENCES users(id),title text NOT NULL,summary text NOT NULL DEFAULT '',category text NOT NULL DEFAULT 'mystery',difficulty text NOT NULL DEFAULT 'beginner',revision bigint NOT NULL DEFAULT 1,content jsonb NOT NULL,layout_revision bigint NOT NULL DEFAULT 1,layout jsonb NOT NULL DEFAULT '{}',validation jsonb,reviewed_hash text,current_release_id uuid,archived_at bigint,created_at bigint NOT NULL,updated_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_project_members(project_id uuid REFERENCES c2_projects(id),user_id uuid REFERENCES users(id),roles text[] NOT NULL CHECK(roles <@ ARRAY['editor','reviewer','publisher']),PRIMARY KEY(project_id,user_id))"
    )

    execute(
      "CREATE TABLE c2_releases(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),content_hash text NOT NULL,content jsonb NOT NULL,status text NOT NULL CHECK(status IN ('published','withdrawn','blocked')),created_by uuid REFERENCES users(id),published_at bigint NOT NULL,UNIQUE(project_id,content_hash))"
    )

    execute(
      "ALTER TABLE c2_projects ADD FOREIGN KEY(current_release_id) REFERENCES c2_releases(id)"
    )

    execute(
      "CREATE TABLE c2_rooms(id uuid PRIMARY KEY,release_id uuid NOT NULL REFERENCES c2_releases(id),host_user_id uuid NOT NULL REFERENCES users(id),status text NOT NULL CHECK(status IN ('lobby','active','suspended','ending','finished','abandoned')),state jsonb NOT NULL,revision bigint NOT NULL DEFAULT 1,owner_id text,owner_epoch bigint NOT NULL DEFAULT 0,lease_until bigint,invite_hash text UNIQUE,invite_cipher bytea,invite_expires_at bigint,updated_at bigint NOT NULL,created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_room_members(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),user_id uuid NOT NULL REFERENCES users(id),role_id text,ready boolean NOT NULL DEFAULT false,control_epoch bigint NOT NULL DEFAULT 1,device_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL DEFAULT 0,ack_seq bigint NOT NULL DEFAULT 0,last_seen_at bigint NOT NULL,joined_at bigint NOT NULL,UNIQUE(room_id,user_id),UNIQUE(room_id,role_id),UNIQUE(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_actor_states(room_id uuid NOT NULL,member_id uuid NOT NULL,location_id text NOT NULL,ap_remaining integer NOT NULL,ap_reserved integer NOT NULL,ap_budget integer NOT NULL,ended boolean NOT NULL,PRIMARY KEY(room_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id),CHECK(0<=ap_reserved AND ap_reserved<=ap_remaining AND ap_remaining<=ap_budget))"
    )

    execute(
      "CREATE TABLE c2_intents(id uuid PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,step_id uuid NOT NULL,status text NOT NULL CHECK(status IN ('queued','locked','resolved','invalidated','cancelled','replaced')),cost integer NOT NULL CHECK(cost>=0),payload jsonb NOT NULL,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE UNIQUE INDEX c2_active_intent ON c2_intents(room_id,member_id,step_id) WHERE status IN ('queued','locked')"
    )

    execute(
      "CREATE TABLE c2_commands(room_id uuid NOT NULL,member_id uuid NOT NULL,command_id uuid NOT NULL,payload_hash text NOT NULL,result jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,command_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_step_settlements(room_id uuid NOT NULL REFERENCES c2_rooms(id),step_id uuid NOT NULL,record jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,step_id))"
    )

    execute(
      "CREATE TABLE c2_endings(room_id uuid PRIMARY KEY REFERENCES c2_rooms(id),ending_id text NOT NULL,created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_knowledge(room_id uuid NOT NULL,member_id uuid NOT NULL,clue_id text NOT NULL,PRIMARY KEY(room_id,member_id,clue_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_known_locations(room_id uuid NOT NULL,member_id uuid NOT NULL,location_id text NOT NULL,PRIMARY KEY(room_id,member_id,location_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_ownership(room_id uuid NOT NULL,item_id text NOT NULL,member_id uuid NOT NULL,version bigint NOT NULL,PRIMARY KEY(room_id,item_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_offers(id uuid PRIMARY KEY,room_id uuid NOT NULL,item_id text NOT NULL,from_member_id uuid NOT NULL,to_member_id uuid NOT NULL,status text NOT NULL,expires_at bigint NOT NULL,version bigint NOT NULL,FOREIGN KEY(room_id,from_member_id) REFERENCES c2_room_members(room_id,id),FOREIGN KEY(room_id,to_member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE UNIQUE INDEX c2_pending_offer ON c2_offers(room_id,item_id) WHERE status='pending'"
    )

    execute(
      "CREATE TABLE c2_view_events(room_id uuid NOT NULL,member_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL,base_view_seq bigint NOT NULL,view jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,stream_id,view_seq),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_outbox(id bigserial PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL,created_at bigint NOT NULL,delivered_at bigint,FOREIGN KEY(room_id,member_id,stream_id,view_seq) REFERENCES c2_view_events(room_id,member_id,stream_id,view_seq))"
    )

    execute(
      "CREATE TABLE c2_socket_tickets(token_hash text PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,session_id uuid NOT NULL REFERENCES sessions(id),device_id uuid NOT NULL,control_epoch bigint NOT NULL,expires_at bigint NOT NULL,consumed boolean NOT NULL DEFAULT false,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE c2_previews(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),user_id uuid NOT NULL REFERENCES users(id),revision bigint NOT NULL,state jsonb NOT NULL,clock bigint NOT NULL,expires_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_reviews(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),content_hash text NOT NULL,decision text NOT NULL,reason text NOT NULL,actor_id uuid NOT NULL REFERENCES users(id),created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_audit(id bigserial PRIMARY KEY,actor_id uuid REFERENCES users(id),scope text NOT NULL,entity_id uuid,action text NOT NULL,details jsonb NOT NULL DEFAULT '{}',created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_tasks(id uuid PRIMARY KEY,project_id uuid REFERENCES c2_projects(id),room_id uuid REFERENCES c2_rooms(id),user_id uuid NOT NULL REFERENCES users(id),kind text NOT NULL,status text NOT NULL,generation bigint NOT NULL DEFAULT 1,input jsonb NOT NULL,input_hash text NOT NULL,output jsonb,lease_hash text,lease_until bigint,cancel_requested boolean NOT NULL DEFAULT false,created_at bigint NOT NULL,updated_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_task_attempts(task_id uuid NOT NULL REFERENCES c2_tasks(id),attempt_no bigint NOT NULL,lease_hash text NOT NULL,started_at bigint NOT NULL,finished_at bigint,error_code text,usage jsonb,PRIMARY KEY(task_id,attempt_no))"
    )

    execute(
      "CREATE TABLE c2_sources(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),source_hash text NOT NULL,title text NOT NULL,rights_note text NOT NULL,chapters jsonb NOT NULL,created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE c2_field_locks(project_id uuid NOT NULL REFERENCES c2_projects(id),pointer text NOT NULL,locked_by uuid NOT NULL REFERENCES users(id),PRIMARY KEY(project_id,pointer))"
    )

    execute("CREATE INDEX c2_room_status ON c2_rooms(status,updated_at)")
    execute("CREATE INDEX c2_member_user ON c2_room_members(user_id,room_id)")
    execute("CREATE INDEX c2_task_queue ON c2_tasks(status,updated_at)")
    execute("CREATE INDEX c2_outbox_pending ON c2_outbox(id) WHERE delivered_at IS NULL")

    execute(
      "CREATE OR REPLACE FUNCTION c2_release_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_hash IS DISTINCT FROM OLD.content_hash OR NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION 'published C2 content is immutable'; END IF; RETURN NEW; END $$"
    )

    execute(
      "CREATE TRIGGER c2_release_frozen BEFORE UPDATE ON c2_releases FOR EACH ROW EXECUTE FUNCTION c2_release_immutable()"
    )
  end

  def down,
    do: raise("C2 is an expand migration; rollback code without deleting live rooms or releases")
end
