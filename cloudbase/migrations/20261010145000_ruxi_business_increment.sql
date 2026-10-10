-- Forward business schema; HTTP runtime replaces Oban scheduling.
SET LOCAL search_path = ruxi, pg_catalog;

-- 20261008000500_telemetry.exs
CREATE TABLE telemetry_events (
  event_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  session_id uuid NOT NULL,
  event_name text NOT NULL,
  schema_version integer NOT NULL CHECK(schema_version=1),
  app_version text NOT NULL,
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  properties jsonb NOT NULL
);

CREATE INDEX telemetry_retention_idx ON telemetry_events(received_at);

CREATE INDEX telemetry_user_idx ON telemetry_events(user_id);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008000500,now());

-- 20261008000600_chat_reports.exs
CREATE TABLE chat_reports (
  id uuid PRIMARY KEY,
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  reporter_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  sender_member_id uuid,
  message_id uuid NOT NULL,
  message_text text,
  reason text NOT NULL CHECK(reason IN ('harassment','privacy','spam','other')),
  status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','dismissed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reviewed_at timestamptz,
  FOREIGN KEY(room_id,sender_member_id) REFERENCES room_members(room_id,id) ON DELETE CASCADE
);

CREATE INDEX chat_report_queue_idx ON chat_reports(status,created_at);

CREATE UNIQUE INDEX chat_report_dedup_idx ON chat_reports(reporter_user_id,room_id,message_id);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008000600,now());

-- 20261008000700_production_assets.exs
CREATE TABLE assets (
  id uuid PRIMARY KEY, created_by uuid REFERENCES users(id),
  filename text NOT NULL, mime_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 524288000),
  sha256 text NOT NULL, object_key text NOT NULL UNIQUE,
  status text NOT NULL CHECK(status IN ('uploading','uploaded','processing','ready','quarantined')),
  upload_expires_at bigint NOT NULL, created_at bigint NOT NULL,
  duration_ms bigint, outputs jsonb, error_code text,
  rights_source text NOT NULL DEFAULT ''
);

ALTER TABLE work_items ADD COLUMN created_by uuid REFERENCES users(id);

CREATE INDEX work_ready_idx ON work_items(kind,status,created_at);

CREATE INDEX assets_creator_idx ON assets(created_by,created_at);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008000700,now());

-- 20261008000800_operational_jobs.exs
CREATE TABLE ruxi.room_summaries (
  room_id uuid PRIMARY KEY,
  content_version_id uuid NOT NULL,
  seat_count integer NOT NULL,
  ending_code text,
  lifecycle text NOT NULL,
  started_at bigint,
  terminal_at bigint NOT NULL
);

CREATE INDEX room_summaries_terminal ON ruxi.room_summaries(terminal_at);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008000800,now());

-- 20261008000900_object_retention.exs
ALTER TABLE ruxi.work_items ADD COLUMN objects_purged_at bigint;
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008000900,now());

-- 20261008001000_frozen_electorate.exs
ALTER TABLE ruxi.vote_rounds ADD COLUMN electorate_frozen boolean NOT NULL DEFAULT false;

CREATE TABLE ruxi.vote_electorate (
  room_id uuid NOT NULL, round_id uuid NOT NULL, member_id uuid NOT NULL,
  PRIMARY KEY(room_id,round_id,member_id),
  FOREIGN KEY(room_id,round_id) REFERENCES ruxi.vote_rounds(room_id,id) ON DELETE CASCADE,
  FOREIGN KEY(room_id,member_id) REFERENCES ruxi.room_members(room_id,id)
);

INSERT INTO ruxi.vote_electorate SELECT r.room_id,r.id,m.id FROM ruxi.vote_rounds r JOIN ruxi.room_members m ON m.room_id=r.room_id WHERE m.role_code IS NOT NULL;

INSERT INTO ruxi.vote_electorate SELECT room_id,round_id,member_id FROM ruxi.votes ON CONFLICT DO NOTHING;

ALTER TABLE ruxi.votes ADD CONSTRAINT votes_frozen_member_fk FOREIGN KEY(room_id,round_id,member_id) REFERENCES ruxi.vote_electorate(room_id,round_id,member_id);

UPDATE ruxi.vote_rounds SET electorate_frozen=true;

CREATE FUNCTION ruxi.guard_electorate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE frozen boolean;
BEGIN
  IF TG_OP='DELETE' THEN
    SELECT electorate_frozen INTO frozen FROM ruxi.vote_rounds WHERE room_id=OLD.room_id AND id=OLD.round_id;
  ELSE
    SELECT electorate_frozen INTO frozen FROM ruxi.vote_rounds WHERE room_id=NEW.room_id AND id=NEW.round_id;
  END IF;
  IF frozen THEN RAISE EXCEPTION 'electorate is frozen'; END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;

CREATE TRIGGER electorate_immutable BEFORE INSERT OR UPDATE OR DELETE ON ruxi.vote_electorate FOR EACH ROW EXECUTE FUNCTION ruxi.guard_electorate();
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008001000,now());

-- 20261008001100_foreign_key_indexes.exs
CREATE INDEX outbox_event_reference ON ruxi.outbox(room_id,member_id,seq);

CREATE INDEX work_room_reference ON ruxi.work_items(room_id);

CREATE INDEX ticket_session_reference ON ruxi.socket_tickets(session_id);

CREATE INDEX report_room_reference ON ruxi.chat_reports(room_id);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008001100,now());

-- 20261008001200_public_recap.exs
CREATE TABLE room_public_events(room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,seq bigint NOT NULL CHECK(seq>0),kind text NOT NULL CHECK(kind IN ('phase','lifecycle','shared_clue')),label text NOT NULL CHECK(length(label) BETWEEN 1 AND 500),occurred_at bigint NOT NULL,PRIMARY KEY(room_id,seq));
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008001200,now());

-- 20261008001300_accounts_catalog.exs
CREATE TABLE player_accounts (user_id uuid PRIMARY KEY REFERENCES users(id),username text UNIQUE NOT NULL,password_hash text NOT NULL,bio text NOT NULL DEFAULT '',created_at bigint NOT NULL);

CREATE TABLE story_favorites (user_id uuid REFERENCES users(id),story_id uuid REFERENCES stories(id),created_at bigint NOT NULL,PRIMARY KEY(user_id,story_id));

CREATE INDEX story_favorites_story_idx ON story_favorites(story_id);

ALTER TABLE stories ADD COLUMN category text NOT NULL DEFAULT 'mystery' CHECK(category IN ('mystery','emotion','scifi','adventure')), ADD COLUMN difficulty text NOT NULL DEFAULT 'beginner' CHECK(difficulty IN ('beginner','intermediate','advanced'));
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261008001300,now());

-- 20261009001400_c2_worlds.exs
CREATE TABLE c2_projects(id uuid PRIMARY KEY,owner_id uuid NOT NULL REFERENCES users(id),title text NOT NULL,summary text NOT NULL DEFAULT '',category text NOT NULL DEFAULT 'mystery',difficulty text NOT NULL DEFAULT 'beginner',revision bigint NOT NULL DEFAULT 1,content jsonb NOT NULL,layout_revision bigint NOT NULL DEFAULT 1,layout jsonb NOT NULL DEFAULT '{}',validation jsonb,reviewed_hash text,current_release_id uuid,archived_at bigint,created_at bigint NOT NULL,updated_at bigint NOT NULL);

CREATE TABLE c2_project_members(project_id uuid REFERENCES c2_projects(id),user_id uuid REFERENCES users(id),roles text[] NOT NULL CHECK(roles <@ ARRAY['editor','reviewer','publisher']),PRIMARY KEY(project_id,user_id));

CREATE TABLE c2_releases(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),content_hash text NOT NULL,content jsonb NOT NULL,status text NOT NULL CHECK(status IN ('published','withdrawn','blocked')),created_by uuid REFERENCES users(id),published_at bigint NOT NULL,UNIQUE(project_id,content_hash));

ALTER TABLE c2_projects ADD FOREIGN KEY(current_release_id) REFERENCES c2_releases(id);

CREATE TABLE c2_rooms(id uuid PRIMARY KEY,release_id uuid NOT NULL REFERENCES c2_releases(id),host_user_id uuid NOT NULL REFERENCES users(id),status text NOT NULL CHECK(status IN ('lobby','active','suspended','ending','finished','abandoned')),state jsonb NOT NULL,revision bigint NOT NULL DEFAULT 1,owner_id text,owner_epoch bigint NOT NULL DEFAULT 0,lease_until bigint,invite_hash text UNIQUE,invite_cipher bytea,invite_expires_at bigint,updated_at bigint NOT NULL,created_at bigint NOT NULL);

CREATE TABLE c2_room_members(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),user_id uuid NOT NULL REFERENCES users(id),role_id text,ready boolean NOT NULL DEFAULT false,control_epoch bigint NOT NULL DEFAULT 1,device_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL DEFAULT 0,ack_seq bigint NOT NULL DEFAULT 0,last_seen_at bigint NOT NULL,joined_at bigint NOT NULL,UNIQUE(room_id,user_id),UNIQUE(room_id,role_id),UNIQUE(room_id,id));

CREATE TABLE c2_actor_states(room_id uuid NOT NULL,member_id uuid NOT NULL,location_id text NOT NULL,ap_remaining integer NOT NULL,ap_reserved integer NOT NULL,ap_budget integer NOT NULL,ended boolean NOT NULL,PRIMARY KEY(room_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id),CHECK(0<=ap_reserved AND ap_reserved<=ap_remaining AND ap_remaining<=ap_budget));

CREATE TABLE c2_intents(id uuid PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,step_id uuid NOT NULL,status text NOT NULL CHECK(status IN ('queued','locked','resolved','invalidated','cancelled','replaced')),cost integer NOT NULL CHECK(cost>=0),payload jsonb NOT NULL,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE UNIQUE INDEX c2_active_intent ON c2_intents(room_id,member_id,step_id) WHERE status IN ('queued','locked');

CREATE TABLE c2_commands(room_id uuid NOT NULL,member_id uuid NOT NULL,command_id uuid NOT NULL,payload_hash text NOT NULL,result jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,command_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_step_settlements(room_id uuid NOT NULL REFERENCES c2_rooms(id),step_id uuid NOT NULL,record jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,step_id));

CREATE TABLE c2_endings(room_id uuid PRIMARY KEY REFERENCES c2_rooms(id),ending_id text NOT NULL,created_at bigint NOT NULL);

CREATE TABLE c2_knowledge(room_id uuid NOT NULL,member_id uuid NOT NULL,clue_id text NOT NULL,PRIMARY KEY(room_id,member_id,clue_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_known_locations(room_id uuid NOT NULL,member_id uuid NOT NULL,location_id text NOT NULL,PRIMARY KEY(room_id,member_id,location_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_ownership(room_id uuid NOT NULL,item_id text NOT NULL,member_id uuid NOT NULL,version bigint NOT NULL,PRIMARY KEY(room_id,item_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_offers(id uuid PRIMARY KEY,room_id uuid NOT NULL,item_id text NOT NULL,from_member_id uuid NOT NULL,to_member_id uuid NOT NULL,status text NOT NULL,expires_at bigint NOT NULL,version bigint NOT NULL,FOREIGN KEY(room_id,from_member_id) REFERENCES c2_room_members(room_id,id),FOREIGN KEY(room_id,to_member_id) REFERENCES c2_room_members(room_id,id));

CREATE UNIQUE INDEX c2_pending_offer ON c2_offers(room_id,item_id) WHERE status='pending';

CREATE TABLE c2_view_events(room_id uuid NOT NULL,member_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL,base_view_seq bigint NOT NULL,view jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,stream_id,view_seq),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_outbox(id bigserial PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,stream_id uuid NOT NULL,view_seq bigint NOT NULL,created_at bigint NOT NULL,delivered_at bigint,FOREIGN KEY(room_id,member_id,stream_id,view_seq) REFERENCES c2_view_events(room_id,member_id,stream_id,view_seq));

CREATE TABLE c2_socket_tickets(token_hash text PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,session_id uuid NOT NULL REFERENCES sessions(id),device_id uuid NOT NULL,control_epoch bigint NOT NULL,expires_at bigint NOT NULL,consumed boolean NOT NULL DEFAULT false,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_previews(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),user_id uuid NOT NULL REFERENCES users(id),revision bigint NOT NULL,state jsonb NOT NULL,clock bigint NOT NULL,expires_at bigint NOT NULL);

CREATE TABLE c2_reviews(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),content_hash text NOT NULL,decision text NOT NULL,reason text NOT NULL,actor_id uuid NOT NULL REFERENCES users(id),created_at bigint NOT NULL);

CREATE TABLE c2_audit(id bigserial PRIMARY KEY,actor_id uuid REFERENCES users(id),scope text NOT NULL,entity_id uuid,action text NOT NULL,details jsonb NOT NULL DEFAULT '{}',created_at bigint NOT NULL);

CREATE TABLE c2_tasks(id uuid PRIMARY KEY,project_id uuid REFERENCES c2_projects(id),room_id uuid REFERENCES c2_rooms(id),user_id uuid NOT NULL REFERENCES users(id),kind text NOT NULL,status text NOT NULL,generation bigint NOT NULL DEFAULT 1,input jsonb NOT NULL,input_hash text NOT NULL,output jsonb,lease_hash text,lease_until bigint,cancel_requested boolean NOT NULL DEFAULT false,created_at bigint NOT NULL,updated_at bigint NOT NULL);

CREATE TABLE c2_task_attempts(task_id uuid NOT NULL REFERENCES c2_tasks(id),attempt_no bigint NOT NULL,lease_hash text NOT NULL,started_at bigint NOT NULL,finished_at bigint,error_code text,usage jsonb,PRIMARY KEY(task_id,attempt_no));

CREATE TABLE c2_sources(id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES c2_projects(id),source_hash text NOT NULL,title text NOT NULL,rights_note text NOT NULL,chapters jsonb NOT NULL,created_at bigint NOT NULL);

CREATE TABLE c2_field_locks(project_id uuid NOT NULL REFERENCES c2_projects(id),pointer text NOT NULL,locked_by uuid NOT NULL REFERENCES users(id),PRIMARY KEY(project_id,pointer));

CREATE INDEX c2_room_status ON c2_rooms(status,updated_at);

CREATE INDEX c2_member_user ON c2_room_members(user_id,room_id);

CREATE INDEX c2_task_queue ON c2_tasks(status,updated_at);

CREATE INDEX c2_outbox_pending ON c2_outbox(id) WHERE delivered_at IS NULL;

CREATE OR REPLACE FUNCTION c2_release_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_hash IS DISTINCT FROM OLD.content_hash OR NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION 'published C2 content is immutable'; END IF; RETURN NEW; END $$;

CREATE TRIGGER c2_release_frozen BEFORE UPDATE ON c2_releases FOR EACH ROW EXECUTE FUNCTION c2_release_immutable();
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001400,now());

-- 20261009001500_c2_favorites.exs
CREATE TABLE c2_favorites(user_id uuid NOT NULL REFERENCES users(id),project_id uuid NOT NULL REFERENCES c2_projects(id),created_at bigint NOT NULL,PRIMARY KEY(user_id,project_id));
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001500,now());

-- 20261009001600_c3_draw_journal.exs
CREATE TABLE c3_resolution_draws(room_id uuid NOT NULL,step_id uuid NOT NULL,intent_id uuid NOT NULL,draw_slot integer NOT NULL,roll integer NOT NULL CHECK(roll BETWEEN 1 AND 100),algorithm_version text NOT NULL,owner_epoch bigint NOT NULL,created_at bigint NOT NULL,abandoned boolean NOT NULL DEFAULT false,PRIMARY KEY(room_id,step_id,intent_id,draw_slot));

CREATE INDEX c3_draw_retention ON c3_resolution_draws(created_at);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001600,now());

-- 20261009001700_scene_communication.exs
CREATE TABLE c2_chat_messages(id uuid PRIMARY KEY,room_id uuid NOT NULL,sender_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,scope text NOT NULL CHECK(scope IN ('global','scene','faction')),body text NOT NULL CHECK(char_length(body) BETWEEN 1 AND 1000),created_at bigint NOT NULL,UNIQUE(room_id,sender_id,request_id),FOREIGN KEY(room_id,sender_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_chat_recipients(room_id uuid NOT NULL,message_id uuid REFERENCES c2_chat_messages(id) ON DELETE CASCADE,member_id uuid NOT NULL,PRIMARY KEY(message_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE INDEX c2_chat_history ON c2_chat_recipients(room_id,member_id);

CREATE TABLE c2_voice_participation(room_id uuid NOT NULL,member_id uuid NOT NULL,enabled boolean NOT NULL DEFAULT false,revision bigint NOT NULL DEFAULT 0,device_id uuid NOT NULL,control_epoch bigint NOT NULL,restricted boolean NOT NULL DEFAULT false,PRIMARY KEY(room_id,member_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_communication_requests(room_id uuid NOT NULL,member_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,result jsonb NOT NULL,created_at bigint NOT NULL,PRIMARY KEY(room_id,member_id,request_id),FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE TABLE c2_communication_reports(id uuid PRIMARY KEY,room_id uuid NOT NULL,reporter_id uuid NOT NULL,target_id uuid NOT NULL,request_id uuid NOT NULL,fingerprint text NOT NULL,kind text NOT NULL,reason text NOT NULL,description text NOT NULL,created_at bigint NOT NULL,UNIQUE(room_id,reporter_id,request_id),FOREIGN KEY(room_id,reporter_id) REFERENCES c2_room_members(room_id,id),FOREIGN KEY(room_id,target_id) REFERENCES c2_room_members(room_id,id));
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001700,now());

-- 20261009001800_voice_runtime.exs
ALTER TABLE c2_rooms ADD COLUMN voice_revision bigint NOT NULL DEFAULT 0;

CREATE TABLE c2_voice_channels(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),scene_id text NOT NULL,generation bigint NOT NULL,rtc_room_id text NOT NULL UNIQUE,status text NOT NULL,roster jsonb NOT NULL,max_token_expires_at bigint NOT NULL DEFAULT 0,UNIQUE(room_id,scene_id,generation));

CREATE UNIQUE INDEX c2_voice_current ON c2_voice_channels(room_id,scene_id) WHERE status IN ('active','opening');

CREATE TABLE c2_voice_leases(id uuid PRIMARY KEY,room_id uuid NOT NULL,member_id uuid NOT NULL,channel_id uuid NOT NULL REFERENCES c2_voice_channels(id),device_id uuid NOT NULL,control_epoch bigint NOT NULL,rtc_uid text NOT NULL,state text NOT NULL,expires_at bigint NOT NULL,token_expires_at bigint NOT NULL,created_at bigint NOT NULL,last_seen_at bigint NOT NULL,FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id));

CREATE UNIQUE INDEX c2_voice_active_lease ON c2_voice_leases(room_id,member_id) WHERE state IN ('issued','connected');

CREATE TABLE c2_voice_transitions(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),owner_epoch bigint NOT NULL,base_revision bigint NOT NULL,proposed_state jsonb,channel_ids uuid[] NOT NULL,phase text NOT NULL,attempts integer NOT NULL DEFAULT 0,created_at bigint NOT NULL,updated_at bigint NOT NULL);

CREATE UNIQUE INDEX c2_voice_pending ON c2_voice_transitions(room_id) WHERE phase IN ('retiring','blocked','fenced');

CREATE TABLE c2_voice_usage(lease_id uuid PRIMARY KEY REFERENCES c2_voice_leases(id),room_id uuid NOT NULL REFERENCES c2_rooms(id),joined_at bigint NOT NULL,left_at bigint,confidence text NOT NULL DEFAULT 'estimated');
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001800,now());

-- 20261009001900_communication_operations.exs
ALTER TABLE c2_rooms ADD COLUMN voice_disabled boolean NOT NULL DEFAULT false;

CREATE TABLE c2_voice_operations(id uuid PRIMARY KEY,room_id uuid NOT NULL REFERENCES c2_rooms(id),admin_id uuid NOT NULL REFERENCES users(id),request_id uuid NOT NULL,fingerprint text NOT NULL,action text NOT NULL,reason text NOT NULL,created_at bigint NOT NULL,UNIQUE(admin_id,request_id));
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009001900,now());

-- 20261009002000_voice_budget.exs
CREATE TABLE c2_voice_budget_days(day date PRIMARY KEY,reached_at bigint);

CREATE TABLE c2_voice_daily_usage(day date PRIMARY KEY,estimated_ms bigint NOT NULL DEFAULT 0);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009002000,now());

-- 20261009002100_voice_socket_presence.exs
ALTER TABLE c2_voice_participation ADD COLUMN socket_ref text;
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261009002100,now());

-- 20261010002200_voice_targeted_revocation.exs
ALTER TABLE c2_voice_channels ADD COLUMN ban_accepted_at bigint;

CREATE TABLE c2_voice_revocations (
  id uuid PRIMARY KEY, room_id uuid NOT NULL REFERENCES c2_rooms(id) ON DELETE CASCADE,
  member_id uuid NOT NULL, channel_id uuid NOT NULL REFERENCES c2_voice_channels(id) ON DELETE CASCADE,
  rtc_uid text NOT NULL, token_expires_at bigint NOT NULL,
  phase text NOT NULL DEFAULT 'pending', accepted_at bigint, created_at bigint NOT NULL,
  UNIQUE(channel_id,rtc_uid),
  FOREIGN KEY(room_id,member_id) REFERENCES c2_room_members(room_id,id) ON DELETE CASCADE
);

CREATE INDEX c2_voice_revocations_pending ON c2_voice_revocations(room_id) WHERE phase='pending';
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES (20261010002200,now());
REVOKE ALL ON ALL TABLES IN SCHEMA ruxi FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ruxi FROM PUBLIC, anon, authenticated;
