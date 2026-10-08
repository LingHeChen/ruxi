defmodule Ruxi.Repo.Migrations.Initial do
  use Ecto.Migration

  def up do
    execute(
      "CREATE TABLE users (id uuid PRIMARY KEY,display_name text NOT NULL,recovery_hash text UNIQUE,recovery_generation bigint NOT NULL DEFAULT 1)"
    )

    execute(
      "CREATE TABLE sessions (id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),access_hash text UNIQUE NOT NULL,refresh_hash text UNIQUE NOT NULL,device_id uuid NOT NULL,audience text NOT NULL CHECK(audience IN ('player','admin')),expires_at bigint NOT NULL,family_expires_at bigint NOT NULL,revoked boolean NOT NULL DEFAULT false)"
    )

    execute(
      "CREATE TABLE auth_retry_cache (scope text,key_hash text,request_hash text NOT NULL,response_ciphertext bytea NOT NULL,expires_at bigint NOT NULL,PRIMARY KEY(scope,key_hash))"
    )

    execute(
      "CREATE TABLE consumed_refresh (token_hash text PRIMARY KEY,session_id uuid REFERENCES sessions(id))"
    )

    execute(
      "CREATE TABLE admin_roles (user_id uuid REFERENCES users(id),role text CHECK(role IN ('editor','reviewer','publisher')),PRIMARY KEY(user_id,role))"
    )

    execute(
      "CREATE TABLE admin_login_codes (id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),token_hash text UNIQUE,expires_at bigint,consumed_at bigint)"
    )

    execute(
      "CREATE TABLE stories (id uuid PRIMARY KEY,title text NOT NULL,summary text NOT NULL,seat_count integer NOT NULL CHECK(seat_count BETWEEN 2 AND 4),current_version_id uuid)"
    )

    execute(
      "CREATE TABLE content_versions (id uuid PRIMARY KEY,story_id uuid REFERENCES stories(id),graph jsonb NOT NULL,revision bigint NOT NULL DEFAULT 1,content_hash text NOT NULL,status text NOT NULL,availability text NOT NULL DEFAULT 'available',approved_hash text,validation jsonb,published_at bigint)"
    )

    execute(
      "ALTER TABLE stories ADD FOREIGN KEY(current_version_id) REFERENCES content_versions(id)"
    )

    execute(
      "CREATE TABLE rooms (id uuid PRIMARY KEY,content_version_id uuid NOT NULL REFERENCES content_versions(id),state_json jsonb NOT NULL,lifecycle text NOT NULL,deadline_at bigint,revision bigint NOT NULL DEFAULT 0,owner_instance text,owner_epoch bigint NOT NULL DEFAULT 0,lease_until bigint,updated_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE room_members (id uuid PRIMARY KEY,room_id uuid REFERENCES rooms(id),user_id uuid REFERENCES users(id),role_code text,status text NOT NULL DEFAULT 'joined',control_generation bigint NOT NULL DEFAULT 1,device_id uuid,view_seq bigint NOT NULL DEFAULT 0,replay_floor_seq bigint NOT NULL DEFAULT 0,UNIQUE(room_id,id),UNIQUE(room_id,user_id),UNIQUE(room_id,role_code) DEFERRABLE INITIALLY DEFERRED)"
    )

    execute(
      "CREATE TABLE room_items (room_id uuid REFERENCES rooms(id),item_id text,owner_member_id uuid,version bigint NOT NULL,PRIMARY KEY(room_id,item_id),FOREIGN KEY(room_id,owner_member_id) REFERENCES room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE item_offers (room_id uuid REFERENCES rooms(id),id uuid,from_member_id uuid,to_member_id uuid,item_id text,status text NOT NULL,expires_at bigint NOT NULL,item_version bigint NOT NULL,PRIMARY KEY(room_id,id),FOREIGN KEY(room_id,from_member_id) REFERENCES room_members(room_id,id),FOREIGN KEY(room_id,to_member_id) REFERENCES room_members(room_id,id),FOREIGN KEY(room_id,item_id) REFERENCES room_items(room_id,item_id))"
    )

    execute(
      "CREATE UNIQUE INDEX one_pending_offer ON item_offers(room_id,item_id) WHERE status='pending'"
    )

    execute(
      "CREATE TABLE vote_rounds (room_id uuid REFERENCES rooms(id),id uuid,options_json jsonb NOT NULL,display_options_json jsonb NOT NULL,status text NOT NULL,PRIMARY KEY(room_id,id))"
    )

    execute(
      "CREATE TABLE votes (room_id uuid,round_id uuid,member_id uuid,option_id text NOT NULL,PRIMARY KEY(room_id,round_id,member_id),FOREIGN KEY(room_id,round_id) REFERENCES vote_rounds(room_id,id),FOREIGN KEY(room_id,member_id) REFERENCES room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE vote_settlements (room_id uuid,round_id uuid,winner text NOT NULL,tally jsonb NOT NULL,PRIMARY KEY(room_id,round_id),FOREIGN KEY(room_id,round_id) REFERENCES vote_rounds(room_id,id))"
    )

    execute(
      "CREATE TABLE account_commands (user_id uuid REFERENCES users(id),operation text,command_id uuid,payload_hash text NOT NULL,response_json jsonb NOT NULL,PRIMARY KEY(user_id,operation,command_id))"
    )

    execute(
      "CREATE TABLE room_commands (room_id uuid,member_id uuid,command_id uuid,payload_hash text NOT NULL,response_json jsonb NOT NULL,PRIMARY KEY(room_id,member_id,command_id),FOREIGN KEY(room_id,member_id) REFERENCES room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE member_view_events (room_id uuid,member_id uuid,seq bigint,event_json jsonb NOT NULL,PRIMARY KEY(room_id,member_id,seq),FOREIGN KEY(room_id,member_id) REFERENCES room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE outbox (id bigserial PRIMARY KEY,room_id uuid,member_id uuid,seq bigint,delivered_at bigint,FOREIGN KEY(room_id,member_id,seq) REFERENCES member_view_events(room_id,member_id,seq))"
    )

    execute("CREATE INDEX outbox_pending ON outbox(id) WHERE delivered_at IS NULL")

    execute(
      "CREATE TABLE socket_tickets (token_hash text PRIMARY KEY,session_id uuid REFERENCES sessions(id),room_id uuid,member_id uuid,device_id uuid,generation bigint,expires_at bigint,consumed boolean DEFAULT false,FOREIGN KEY(room_id,member_id) REFERENCES room_members(room_id,id))"
    )

    execute(
      "CREATE TABLE work_items (id uuid PRIMARY KEY,room_id uuid REFERENCES rooms(id),member_id uuid,phase_id uuid,reservation_id uuid,kind text NOT NULL,input_json jsonb NOT NULL,basis jsonb NOT NULL,status text NOT NULL,attempt integer NOT NULL DEFAULT 0,lease_hash text,lease_until bigint,result_hash text,result_json jsonb,completion_response_json jsonb,completed_attempt integer,created_at bigint NOT NULL)"
    )

    execute(
      "CREATE TABLE work_claims (worker_id text,claim_id uuid,reply_ciphertext bytea,expires_at bigint,PRIMARY KEY(worker_id,claim_id))"
    )

    execute(
      "CREATE TABLE admin_jobs (id uuid PRIMARY KEY,version_id uuid REFERENCES content_versions(id),report jsonb NOT NULL)"
    )

    execute(
      "CREATE TABLE audit_log (id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),operation text NOT NULL,target_id uuid,occurred_at bigint NOT NULL)"
    )
  end

  def down do
    for t <-
          ~w(audit_log admin_jobs work_claims work_items socket_tickets outbox member_view_events room_commands account_commands vote_settlements votes vote_rounds item_offers room_items room_members rooms consumed_refresh auth_retry_cache admin_login_codes admin_roles sessions users stories content_versions),
        do: execute("DROP TABLE IF EXISTS #{t} CASCADE")
  end
end
