-- Provision distinct LOGIN roles through the database administrator first.
-- psql -v runtime_role=ruxi_runtime -v migrator_role=ruxi_migrator -f runtime_permissions.sql
-- No role/password creation or shared-database ownership changes here.
BEGIN;
REVOKE ALL ON SCHEMA ruxi FROM PUBLIC;
GRANT USAGE ON SCHEMA ruxi TO :"runtime_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ruxi TO :"runtime_role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ruxi TO :"runtime_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA ruxi
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA ruxi
  GRANT USAGE, SELECT ON SEQUENCES TO :"runtime_role";
COMMIT;
