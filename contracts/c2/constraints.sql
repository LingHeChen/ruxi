-- PostgreSQL constraint examples. Integrate into Ecto migrations after creating tables.
ALTER TABLE room_members ADD CONSTRAINT member_unique_role UNIQUE(room_id, role_id);
ALTER TABLE room_members ADD CONSTRAINT member_unique_user UNIQUE(room_id, user_id);
ALTER TABLE actor_states ADD CONSTRAINT valid_ap CHECK(ap_reserved >= 0 AND ap_remaining >= ap_reserved);
CREATE UNIQUE INDEX active_intent_per_step ON intents(room_id,member_id,step_id) WHERE status IN ('queued','locked');
CREATE UNIQUE INDEX command_dedup ON commands(room_id,member_id,command_id);
CREATE UNIQUE INDEX view_sequence ON view_events(room_id,member_id,stream_id,view_seq);
CREATE UNIQUE INDEX single_settlement ON settlements(room_id);
CREATE UNIQUE INDEX single_offer ON item_offers(room_id,item_id) WHERE status='pending';
CREATE UNIQUE INDEX one_step_commit ON step_settlements(room_id,step_id);
CREATE UNIQUE INDEX one_ballot ON ballots(vote_id,member_id);
CREATE UNIQUE INDEX one_knowledge ON knowledge(room_id,member_id,clue_id);
CREATE UNIQUE INDEX one_owner ON ownership(room_id,item_id);
CREATE UNIQUE INDEX one_room_owner ON room_owners(room_id);
CREATE UNIQUE INDEX project_membership ON project_memberships(project_id,user_id);
ALTER TABLE room_members ADD CONSTRAINT member_room_identity UNIQUE(room_id,id);
ALTER TABLE actor_states ADD CONSTRAINT same_room_member FOREIGN KEY(room_id,member_id) REFERENCES room_members(room_id,id);
-- Remaining child member references must use the same composite FK pattern.
