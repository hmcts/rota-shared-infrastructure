-- Called inside one psql session; the caller commits only after pg_restore succeeds.

-- ---------------------------------------------------------------------------
-- Transaction and restore lock
-- ---------------------------------------------------------------------------
BEGIN;

DO $$
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('rota-database-restore')) THEN
    RAISE EXCEPTION 'Another database restore is running';
  END IF;
END
$$;

SET ROLE :"restore_owner";
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Save target schema ownership and permissions
-- ---------------------------------------------------------------------------
-- Keep the database, its locale, database grants and server-scoped users intact.
-- Save the target's schema/default grants instead of importing production ACLs.
CREATE TEMP TABLE restore_schema_owner ON COMMIT DROP AS
SELECT pg_get_userbyid(nspowner) AS name
FROM pg_namespace
WHERE nspname = 'public';

CREATE TEMP TABLE restore_schema_grants ON COMMIT DROP AS
SELECT format(
  'GRANT %s ON SCHEMA public TO %s%s',
  acl.privilege_type,
  CASE
    WHEN acl.grantee = 0 THEN 'PUBLIC'
    ELSE quote_ident(pg_get_userbyid(acl.grantee))
  END,
  CASE
    WHEN acl.is_grantable THEN ' WITH GRANT OPTION'
    ELSE ''
  END
) AS sql
FROM pg_namespace n,
LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) acl
WHERE n.nspname = 'public';

CREATE TEMP TABLE restore_default_grants ON COMMIT DROP AS
SELECT format(
  'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT %s ON %s TO %s%s',
  pg_get_userbyid(d.defaclrole),
  acl.privilege_type,
  CASE d.defaclobjtype
    WHEN 'r' THEN 'TABLES'
    WHEN 'S' THEN 'SEQUENCES'
    WHEN 'f' THEN 'FUNCTIONS'
    WHEN 'T' THEN 'TYPES'
  END,
  CASE
    WHEN acl.grantee = 0 THEN 'PUBLIC'
    ELSE quote_ident(pg_get_userbyid(acl.grantee))
  END,
  CASE
    WHEN acl.is_grantable THEN ' WITH GRANT OPTION'
    ELSE ''
  END
) AS sql
FROM pg_default_acl d
JOIN pg_namespace n ON n.oid = d.defaclnamespace,
LATERAL aclexplode(d.defaclacl) acl
WHERE n.nspname = 'public';

-- ---------------------------------------------------------------------------
-- Validate and save configured extensions
-- ---------------------------------------------------------------------------
-- These extensions are enabled by postgres.tf. Reject unexpected public extensions
-- before DROP CASCADE rather than silently changing their configuration.
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE n.nspname = 'public'
      AND e.extname NOT IN ('pg_stat_statements', 'pg_buffercache')
  ) THEN
    RAISE EXCEPTION 'Unexpected extension in public; review it before restoring';
  END IF;
END
$$;

CREATE TEMP TABLE restore_extensions ON COMMIT DROP AS
SELECT format(
  'CREATE EXTENSION %I WITH SCHEMA public VERSION %L',
  e.extname,
  e.extversion
) AS sql
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE n.nspname = 'public';

-- ---------------------------------------------------------------------------
-- Replace the public schema and restore its settings
-- ---------------------------------------------------------------------------
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND backend_type = 'client backend';

DROP SCHEMA public CASCADE;
SELECT format('CREATE SCHEMA public AUTHORIZATION %I', name)
FROM restore_schema_owner
\gexec

SELECT sql FROM restore_extensions
\gexec

SELECT sql FROM restore_schema_grants
\gexec

SELECT sql FROM restore_default_grants
\gexec

-- ---------------------------------------------------------------------------
-- Owner and application grants for restored objects
-- ---------------------------------------------------------------------------
-- Match the owner/application-user model in dev/PET-8240-database-users.
GRANT USAGE, CREATE ON SCHEMA public TO :"restore_owner";
GRANT USAGE ON SCHEMA public TO :"application_user";
SET ROLE :"restore_owner";

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"application_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"application_user";
