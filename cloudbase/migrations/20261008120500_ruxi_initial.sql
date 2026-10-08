--
-- PostgreSQL database dump
--


-- Dumped from database version 17.7 (Homebrew)
-- Dumped by pg_dump version 17.7 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET LOCAL search_path = ruxi, pg_catalog;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ruxi; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ruxi;


--
-- Name: SCHEMA ruxi; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA ruxi IS 'Ruxi portfolio application; isolated from platform and other apps';


--
-- Name: prevent_frozen_content_change(); Type: FUNCTION; Schema: ruxi; Owner: -
--

CREATE FUNCTION ruxi.prevent_frozen_content_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'published' AND
    (NEW.graph IS DISTINCT FROM OLD.graph OR NEW.content_hash IS DISTINCT FROM OLD.content_hash OR NEW.revision IS DISTINCT FROM OLD.revision OR NEW.status IS DISTINCT FROM OLD.status) THEN
    RAISE EXCEPTION 'published content is immutable';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: record_retention_clock(); Type: FUNCTION; Schema: ruxi; Owner: -
--

CREATE FUNCTION ruxi.record_retention_clock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_TABLE_NAME='rooms' THEN
    IF NEW.lifecycle IN ('finished','abandoned') AND NEW.terminal_at IS NULL THEN
      NEW.terminal_at=floor(extract(epoch from clock_timestamp())*1000)::bigint;
    END IF;
  ELSE
    IF NEW.revoked AND NEW.revoked_at IS NULL THEN
      NEW.revoked_at=floor(extract(epoch from clock_timestamp())*1000)::bigint;
    END IF;
  END IF;
  RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_commands; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.account_commands (
    user_id uuid NOT NULL,
    operation text NOT NULL,
    command_id uuid NOT NULL,
    payload_hash text NOT NULL,
    response_json jsonb NOT NULL,
    created_at bigint DEFAULT (floor((EXTRACT(epoch FROM clock_timestamp()) * (1000)::numeric)))::bigint NOT NULL
);


--
-- Name: admin_jobs; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.admin_jobs (
    id uuid NOT NULL,
    version_id uuid,
    report jsonb NOT NULL
);


--
-- Name: admin_login_codes; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.admin_login_codes (
    id uuid NOT NULL,
    user_id uuid,
    token_hash text,
    expires_at bigint,
    consumed_at bigint
);


--
-- Name: admin_roles; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.admin_roles (
    user_id uuid NOT NULL,
    role text NOT NULL,
    CONSTRAINT admin_roles_role_check CHECK ((role = ANY (ARRAY['editor'::text, 'reviewer'::text, 'publisher'::text])))
);


--
-- Name: audit_log; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.audit_log (
    id uuid NOT NULL,
    user_id uuid,
    operation text NOT NULL,
    target_id uuid,
    occurred_at bigint NOT NULL
);


--
-- Name: auth_retry_cache; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.auth_retry_cache (
    scope text NOT NULL,
    key_hash text NOT NULL,
    request_hash text NOT NULL,
    response_ciphertext bytea NOT NULL,
    expires_at bigint NOT NULL
);


--
-- Name: consumed_refresh; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.consumed_refresh (
    token_hash text NOT NULL,
    session_id uuid
);


--
-- Name: content_versions; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.content_versions (
    id uuid NOT NULL,
    story_id uuid,
    graph jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    content_hash text NOT NULL,
    status text NOT NULL,
    availability text DEFAULT 'available'::text NOT NULL,
    approved_hash text,
    validation jsonb,
    published_at bigint
);


--
-- Name: item_offers; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.item_offers (
    room_id uuid NOT NULL,
    id uuid NOT NULL,
    from_member_id uuid,
    to_member_id uuid,
    item_id text,
    status text NOT NULL,
    expires_at bigint NOT NULL,
    item_version bigint NOT NULL,
    CONSTRAINT offer_state CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text, 'cancelled'::text, 'expired'::text])))
);


--
-- Name: member_view_events; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.member_view_events (
    room_id uuid NOT NULL,
    member_id uuid NOT NULL,
    seq bigint NOT NULL,
    event_json jsonb NOT NULL
);


--
-- Name: outbox; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.outbox (
    id bigint NOT NULL,
    room_id uuid,
    member_id uuid,
    seq bigint,
    delivered_at bigint
);


--
-- Name: outbox_id_seq; Type: SEQUENCE; Schema: ruxi; Owner: -
--

CREATE SEQUENCE ruxi.outbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbox_id_seq; Type: SEQUENCE OWNED BY; Schema: ruxi; Owner: -
--

ALTER SEQUENCE ruxi.outbox_id_seq OWNED BY ruxi.outbox.id;


--
-- Name: room_commands; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.room_commands (
    room_id uuid NOT NULL,
    member_id uuid NOT NULL,
    command_id uuid NOT NULL,
    payload_hash text NOT NULL,
    response_json jsonb NOT NULL
);


--
-- Name: room_items; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.room_items (
    room_id uuid NOT NULL,
    item_id text NOT NULL,
    owner_member_id uuid,
    version bigint NOT NULL,
    CONSTRAINT item_version_bounds CHECK (((version >= 1) AND (version <= '9007199254740991'::bigint)))
);


--
-- Name: room_members; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.room_members (
    id uuid NOT NULL,
    room_id uuid,
    user_id uuid,
    role_code text,
    status text DEFAULT 'joined'::text NOT NULL,
    control_generation bigint DEFAULT 1 NOT NULL,
    device_id uuid,
    view_seq bigint DEFAULT 0 NOT NULL,
    replay_floor_seq bigint DEFAULT 0 NOT NULL,
    CONSTRAINT member_seq_bounds CHECK ((((view_seq >= 0) AND (view_seq <= '9007199254740991'::bigint)) AND ((replay_floor_seq >= 0) AND (replay_floor_seq <= view_seq)) AND ((control_generation >= 1) AND (control_generation <= '9007199254740991'::bigint))))
);


--
-- Name: rooms; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.rooms (
    id uuid NOT NULL,
    content_version_id uuid NOT NULL,
    state_json jsonb NOT NULL,
    lifecycle text NOT NULL,
    deadline_at bigint,
    revision bigint DEFAULT 0 NOT NULL,
    owner_instance text,
    owner_epoch bigint DEFAULT 0 NOT NULL,
    lease_until bigint,
    updated_at bigint NOT NULL,
    terminal_at bigint,
    bodies_purged_at bigint,
    CONSTRAINT room_lifecycle CHECK ((lifecycle = ANY (ARRAY['lobby'::text, 'running'::text, 'paused'::text, 'suspended'::text, 'finished'::text, 'abandoned'::text])))
);


--
-- Name: sessions; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.sessions (
    id uuid NOT NULL,
    user_id uuid,
    access_hash text NOT NULL,
    refresh_hash text NOT NULL,
    device_id uuid NOT NULL,
    audience text NOT NULL,
    expires_at bigint NOT NULL,
    family_expires_at bigint NOT NULL,
    revoked boolean DEFAULT false NOT NULL,
    revoked_at bigint,
    CONSTRAINT sessions_audience_check CHECK ((audience = ANY (ARRAY['player'::text, 'admin'::text])))
);


--
-- Name: socket_tickets; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.socket_tickets (
    token_hash text NOT NULL,
    session_id uuid,
    room_id uuid,
    member_id uuid,
    device_id uuid,
    generation bigint,
    expires_at bigint,
    consumed boolean DEFAULT false
);


--
-- Name: stories; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.stories (
    id uuid NOT NULL,
    title text NOT NULL,
    summary text NOT NULL,
    seat_count integer NOT NULL,
    current_version_id uuid,
    CONSTRAINT stories_seat_count_check CHECK (((seat_count >= 2) AND (seat_count <= 4)))
);


--
-- Name: users; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.users (
    id uuid NOT NULL,
    display_name text NOT NULL,
    recovery_hash text,
    recovery_generation bigint DEFAULT 1 NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text, 'erased'::text])))
);


--
-- Name: vote_rounds; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.vote_rounds (
    room_id uuid NOT NULL,
    id uuid NOT NULL,
    options_json jsonb NOT NULL,
    display_options_json jsonb NOT NULL,
    status text NOT NULL
);


--
-- Name: vote_settlements; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.vote_settlements (
    room_id uuid NOT NULL,
    round_id uuid NOT NULL,
    winner text NOT NULL,
    tally jsonb NOT NULL
);


--
-- Name: votes; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.votes (
    room_id uuid NOT NULL,
    round_id uuid NOT NULL,
    member_id uuid NOT NULL,
    option_id text NOT NULL
);


--
-- Name: work_claims; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.work_claims (
    worker_id text NOT NULL,
    claim_id uuid NOT NULL,
    reply_ciphertext bytea,
    expires_at bigint
);


--
-- Name: work_items; Type: TABLE; Schema: ruxi; Owner: -
--

CREATE TABLE ruxi.work_items (
    id uuid NOT NULL,
    room_id uuid,
    member_id uuid,
    phase_id uuid,
    reservation_id uuid,
    kind text NOT NULL,
    input_json jsonb NOT NULL,
    basis jsonb NOT NULL,
    status text NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    lease_hash text,
    lease_until bigint,
    result_hash text,
    result_json jsonb,
    completion_response_json jsonb,
    completed_attempt integer,
    created_at bigint NOT NULL,
    leased_by text
);


--
-- Name: outbox id; Type: DEFAULT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.outbox ALTER COLUMN id SET DEFAULT nextval('ruxi.outbox_id_seq'::regclass);


--
-- Name: account_commands account_commands_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.account_commands
    ADD CONSTRAINT account_commands_pkey PRIMARY KEY (user_id, operation, command_id);


--
-- Name: admin_jobs admin_jobs_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_jobs
    ADD CONSTRAINT admin_jobs_pkey PRIMARY KEY (id);


--
-- Name: admin_login_codes admin_login_codes_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_login_codes
    ADD CONSTRAINT admin_login_codes_pkey PRIMARY KEY (id);


--
-- Name: admin_login_codes admin_login_codes_token_hash_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_login_codes
    ADD CONSTRAINT admin_login_codes_token_hash_key UNIQUE (token_hash);


--
-- Name: admin_roles admin_roles_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_roles
    ADD CONSTRAINT admin_roles_pkey PRIMARY KEY (user_id, role);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: auth_retry_cache auth_retry_cache_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.auth_retry_cache
    ADD CONSTRAINT auth_retry_cache_pkey PRIMARY KEY (scope, key_hash);


--
-- Name: consumed_refresh consumed_refresh_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.consumed_refresh
    ADD CONSTRAINT consumed_refresh_pkey PRIMARY KEY (token_hash);


--
-- Name: content_versions content_versions_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.content_versions
    ADD CONSTRAINT content_versions_pkey PRIMARY KEY (id);


--
-- Name: item_offers item_offers_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.item_offers
    ADD CONSTRAINT item_offers_pkey PRIMARY KEY (room_id, id);


--
-- Name: member_view_events member_view_events_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.member_view_events
    ADD CONSTRAINT member_view_events_pkey PRIMARY KEY (room_id, member_id, seq);


--
-- Name: outbox outbox_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.outbox
    ADD CONSTRAINT outbox_pkey PRIMARY KEY (id);


--
-- Name: room_commands room_commands_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_commands
    ADD CONSTRAINT room_commands_pkey PRIMARY KEY (room_id, member_id, command_id);


--
-- Name: room_items room_items_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_items
    ADD CONSTRAINT room_items_pkey PRIMARY KEY (room_id, item_id);


--
-- Name: room_members room_members_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_pkey PRIMARY KEY (id);


--
-- Name: room_members room_members_room_id_id_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_room_id_id_key UNIQUE (room_id, id);


--
-- Name: room_members room_members_room_id_role_code_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_room_id_role_code_key UNIQUE (room_id, role_code) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: room_members room_members_room_id_user_id_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_room_id_user_id_key UNIQUE (room_id, user_id);


--
-- Name: rooms rooms_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_access_hash_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.sessions
    ADD CONSTRAINT sessions_access_hash_key UNIQUE (access_hash);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_refresh_hash_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.sessions
    ADD CONSTRAINT sessions_refresh_hash_key UNIQUE (refresh_hash);


--
-- Name: socket_tickets socket_tickets_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.socket_tickets
    ADD CONSTRAINT socket_tickets_pkey PRIMARY KEY (token_hash);


--
-- Name: stories stories_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.stories
    ADD CONSTRAINT stories_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_recovery_hash_key; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.users
    ADD CONSTRAINT users_recovery_hash_key UNIQUE (recovery_hash);


--
-- Name: vote_rounds vote_rounds_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.vote_rounds
    ADD CONSTRAINT vote_rounds_pkey PRIMARY KEY (room_id, id);


--
-- Name: vote_settlements vote_settlements_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.vote_settlements
    ADD CONSTRAINT vote_settlements_pkey PRIMARY KEY (room_id, round_id);


--
-- Name: votes votes_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.votes
    ADD CONSTRAINT votes_pkey PRIMARY KEY (room_id, round_id, member_id);


--
-- Name: work_claims work_claims_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.work_claims
    ADD CONSTRAINT work_claims_pkey PRIMARY KEY (worker_id, claim_id);


--
-- Name: work_items work_items_pkey; Type: CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.work_items
    ADD CONSTRAINT work_items_pkey PRIMARY KEY (id);


--
-- Name: account_command_retention; Type: INDEX; Schema: ruxi; Owner: -
--

CREATE INDEX account_command_retention ON ruxi.account_commands USING btree (created_at);


--
-- Name: expired_auth_cache; Type: INDEX; Schema: ruxi; Owner: -
--

CREATE INDEX expired_auth_cache ON ruxi.auth_retry_cache USING btree (expires_at);


--
-- Name: one_pending_offer; Type: INDEX; Schema: ruxi; Owner: -
--

CREATE UNIQUE INDEX one_pending_offer ON ruxi.item_offers USING btree (room_id, item_id) WHERE (status = 'pending'::text);


--
-- Name: outbox_pending; Type: INDEX; Schema: ruxi; Owner: -
--

CREATE INDEX outbox_pending ON ruxi.outbox USING btree (id) WHERE (delivered_at IS NULL);


--
-- Name: retention_terminal; Type: INDEX; Schema: ruxi; Owner: -
--

CREATE INDEX retention_terminal ON ruxi.rooms USING btree (terminal_at) WHERE (lifecycle = ANY (ARRAY['finished'::text, 'abandoned'::text]));


--
-- Name: content_versions immutable_content; Type: TRIGGER; Schema: ruxi; Owner: -
--

CREATE TRIGGER immutable_content BEFORE UPDATE ON ruxi.content_versions FOR EACH ROW EXECUTE FUNCTION ruxi.prevent_frozen_content_change();


--
-- Name: rooms room_retention_clock; Type: TRIGGER; Schema: ruxi; Owner: -
--

CREATE TRIGGER room_retention_clock BEFORE INSERT OR UPDATE ON ruxi.rooms FOR EACH ROW EXECUTE FUNCTION ruxi.record_retention_clock();


--
-- Name: sessions session_retention_clock; Type: TRIGGER; Schema: ruxi; Owner: -
--

CREATE TRIGGER session_retention_clock BEFORE INSERT OR UPDATE ON ruxi.sessions FOR EACH ROW EXECUTE FUNCTION ruxi.record_retention_clock();


--
-- Name: account_commands account_commands_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.account_commands
    ADD CONSTRAINT account_commands_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: admin_jobs admin_jobs_version_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_jobs
    ADD CONSTRAINT admin_jobs_version_id_fkey FOREIGN KEY (version_id) REFERENCES ruxi.content_versions(id);


--
-- Name: admin_login_codes admin_login_codes_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_login_codes
    ADD CONSTRAINT admin_login_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: admin_roles admin_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.admin_roles
    ADD CONSTRAINT admin_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: consumed_refresh consumed_refresh_session_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.consumed_refresh
    ADD CONSTRAINT consumed_refresh_session_id_fkey FOREIGN KEY (session_id) REFERENCES ruxi.sessions(id);


--
-- Name: content_versions content_versions_story_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.content_versions
    ADD CONSTRAINT content_versions_story_id_fkey FOREIGN KEY (story_id) REFERENCES ruxi.stories(id);


--
-- Name: item_offers item_offers_room_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.item_offers
    ADD CONSTRAINT item_offers_room_id_fkey FOREIGN KEY (room_id) REFERENCES ruxi.rooms(id);


--
-- Name: item_offers item_offers_room_id_from_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.item_offers
    ADD CONSTRAINT item_offers_room_id_from_member_id_fkey FOREIGN KEY (room_id, from_member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: item_offers item_offers_room_id_item_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.item_offers
    ADD CONSTRAINT item_offers_room_id_item_id_fkey FOREIGN KEY (room_id, item_id) REFERENCES ruxi.room_items(room_id, item_id);


--
-- Name: item_offers item_offers_room_id_to_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.item_offers
    ADD CONSTRAINT item_offers_room_id_to_member_id_fkey FOREIGN KEY (room_id, to_member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: member_view_events member_view_events_room_id_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.member_view_events
    ADD CONSTRAINT member_view_events_room_id_member_id_fkey FOREIGN KEY (room_id, member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: outbox outbox_room_id_member_id_seq_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.outbox
    ADD CONSTRAINT outbox_room_id_member_id_seq_fkey FOREIGN KEY (room_id, member_id, seq) REFERENCES ruxi.member_view_events(room_id, member_id, seq);


--
-- Name: room_commands room_commands_room_id_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_commands
    ADD CONSTRAINT room_commands_room_id_member_id_fkey FOREIGN KEY (room_id, member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: room_items room_items_room_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_items
    ADD CONSTRAINT room_items_room_id_fkey FOREIGN KEY (room_id) REFERENCES ruxi.rooms(id);


--
-- Name: room_items room_items_room_id_owner_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_items
    ADD CONSTRAINT room_items_room_id_owner_member_id_fkey FOREIGN KEY (room_id, owner_member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: room_members room_members_room_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_room_id_fkey FOREIGN KEY (room_id) REFERENCES ruxi.rooms(id);


--
-- Name: room_members room_members_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.room_members
    ADD CONSTRAINT room_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: rooms rooms_content_version_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.rooms
    ADD CONSTRAINT rooms_content_version_id_fkey FOREIGN KEY (content_version_id) REFERENCES ruxi.content_versions(id);


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES ruxi.users(id);


--
-- Name: socket_tickets socket_tickets_room_id_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.socket_tickets
    ADD CONSTRAINT socket_tickets_room_id_member_id_fkey FOREIGN KEY (room_id, member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: socket_tickets socket_tickets_session_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.socket_tickets
    ADD CONSTRAINT socket_tickets_session_id_fkey FOREIGN KEY (session_id) REFERENCES ruxi.sessions(id);


--
-- Name: stories stories_current_version_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.stories
    ADD CONSTRAINT stories_current_version_id_fkey FOREIGN KEY (current_version_id) REFERENCES ruxi.content_versions(id);


--
-- Name: vote_rounds vote_rounds_room_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.vote_rounds
    ADD CONSTRAINT vote_rounds_room_id_fkey FOREIGN KEY (room_id) REFERENCES ruxi.rooms(id);


--
-- Name: vote_settlements vote_settlements_room_id_round_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.vote_settlements
    ADD CONSTRAINT vote_settlements_room_id_round_id_fkey FOREIGN KEY (room_id, round_id) REFERENCES ruxi.vote_rounds(room_id, id);


--
-- Name: votes votes_room_id_member_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.votes
    ADD CONSTRAINT votes_room_id_member_id_fkey FOREIGN KEY (room_id, member_id) REFERENCES ruxi.room_members(room_id, id);


--
-- Name: votes votes_room_id_round_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.votes
    ADD CONSTRAINT votes_room_id_round_id_fkey FOREIGN KEY (room_id, round_id) REFERENCES ruxi.vote_rounds(room_id, id);


--
-- Name: work_items work_items_room_id_fkey; Type: FK CONSTRAINT; Schema: ruxi; Owner: -
--

ALTER TABLE ONLY ruxi.work_items
    ADD CONSTRAINT work_items_room_id_fkey FOREIGN KEY (room_id) REFERENCES ruxi.rooms(id);


--
-- PostgreSQL database dump complete
--


REVOKE ALL ON SCHEMA ruxi FROM PUBLIC;
GRANT USAGE ON SCHEMA ruxi TO cloudbase_postgres_postgres_ngbg4kck;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ruxi TO cloudbase_postgres_postgres_ngbg4kck;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ruxi TO cloudbase_postgres_postgres_ngbg4kck;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ruxi FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ruxi TO cloudbase_postgres_postgres_ngbg4kck;

-- Keep Ecto's bootstrap history inside this schema too.
CREATE TABLE ruxi.schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0) without time zone);
INSERT INTO ruxi.schema_migrations(version,inserted_at) VALUES
(20261008000100, CURRENT_TIMESTAMP),
(20261008000200, CURRENT_TIMESTAMP),
(20261008000300, CURRENT_TIMESTAMP),
(20261008000400, CURRENT_TIMESTAMP);
GRANT SELECT, INSERT, DELETE ON ruxi.schema_migrations TO cloudbase_postgres_postgres_ngbg4kck;
ALTER FUNCTION ruxi.prevent_frozen_content_change() SET search_path=ruxi,pg_catalog;
ALTER FUNCTION ruxi.record_retention_clock() SET search_path=ruxi,pg_catalog;
