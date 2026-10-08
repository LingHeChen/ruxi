-- One-time upgrade for the original local prototype; never run on a shared cloud DB.
BEGIN;
DO $$
DECLARE t text;
BEGIN
  IF current_database() NOT IN ('ruxi_dev','ruxi_test') THEN
    RAISE EXCEPTION 'local prototype migration only';
  END IF;
  CREATE SCHEMA IF NOT EXISTS ruxi;
  IF to_regclass('public.users') IS NOT NULL THEN
    FOREACH t IN ARRAY ARRAY['account_commands','admin_jobs','admin_login_codes','admin_roles',
      'audit_log','auth_retry_cache','consumed_refresh','content_versions','item_offers',
      'member_view_events','outbox','room_commands','room_items','room_members','rooms',
      'schema_migrations','sessions','socket_tickets','stories','users','vote_rounds',
      'vote_settlements','votes','work_claims','work_items'] LOOP
      EXECUTE format('ALTER TABLE public.%I SET SCHEMA ruxi', t);
    END LOOP;
    ALTER FUNCTION public.prevent_frozen_content_change() SET SCHEMA ruxi;
    ALTER FUNCTION public.record_retention_clock() SET SCHEMA ruxi;
  END IF;
END $$;
REVOKE ALL ON SCHEMA ruxi FROM PUBLIC;
COMMIT;
