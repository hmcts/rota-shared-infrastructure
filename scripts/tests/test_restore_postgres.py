"""Optional integration checks against a disposable local PostgreSQL 15 server.

Set RESTORE_TEST_SOCKET, RESTORE_TEST_PORT and RESTORE_TEST_CLIENT_BIN. The client
directory must contain pg_dump/pg_restore 15 and psql. Never point this at Azure.
"""

import getpass
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
ENABLED = all(os.environ.get(k) for k in
              ("RESTORE_TEST_SOCKET", "RESTORE_TEST_PORT", "RESTORE_TEST_CLIENT_BIN"))
FIXTURE_ROLES = (
    "portal_owner", "portal_user", "optimiser_owner", "optimiser_user",
    "restore_reader", "production_only",
)
FIXTURE_DATABASES = tuple("rota_restore_test_" + name for name in ("source", "target", "optimiser"))


@unittest.skipUnless(ENABLED, "requires disposable local PostgreSQL 15")
class PostgreSQLRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        socket = Path(os.environ["RESTORE_TEST_SOCKET"])
        if not socket.is_absolute() or not str(socket).startswith(("/private/tmp", "/tmp")):
            raise RuntimeError("Integration tests require a Unix socket in /tmp")
        cls.environment = {
            **os.environ, "PATH": os.environ["RESTORE_TEST_CLIENT_BIN"] + ":" + os.environ["PATH"],
            "PGHOST": str(socket), "PGPORT": os.environ["RESTORE_TEST_PORT"],
            "PGUSER": getpass.getuser(), "PGDATABASE": "postgres", "PGSSLMODE": "disable",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        cls.created_databases = []
        cls.created_roles = []
        if int(cls.psql("SHOW server_version_num;")) // 10000 != 15:
            raise RuntimeError("Integration tests require a PostgreSQL 15 server")
        cls.check_fixture_names_available()
        cls.addClassCleanup(cls.cleanup_owned_fixtures)
        for name in FIXTURE_ROLES:
            cls.psql(f'CREATE ROLE "{name}";')
            cls.created_roles.append(name)
        for name in FIXTURE_DATABASES:
            cls.psql(f'CREATE DATABASE "{name}";')
            cls.created_databases.append(name)
        cls.psql("""
            CREATE TABLE public.new_table (id serial PRIMARY KEY, value text);
            INSERT INTO public.new_table(value) VALUES ('synthetic');
            GRANT ALL ON public.new_table TO production_only;
            CREATE TABLE public.large_fixture AS
              SELECT i, repeat(md5(i::text), 16) AS value FROM generate_series(1, 40000) i;
        """, "source")
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.archive = Path(cls.directory.name) / "fixture.backup"
        subprocess.run(["pg_dump", "-Fc", "-Z0", "-n", "public", "-f", str(cls.archive),
                        "rota_restore_test_source"], check=True, env=cls.environment)

    @classmethod
    def check_fixture_names_available(cls):
        roles = ", ".join(f"'{name}'" for name in FIXTURE_ROLES)
        databases = ", ".join(f"'{name}'" for name in FIXTURE_DATABASES)
        conflicts = cls.psql(
            f"SELECT 'role:' || rolname FROM pg_roles WHERE rolname IN ({roles}) "
            f"UNION ALL SELECT 'database:' || datname FROM pg_database WHERE datname IN ({databases});"
        )
        if conflicts:
            raise RuntimeError("Fixture names already exist; refusing to change them: " + conflicts)

    @classmethod
    def cleanup_owned_fixtures(cls):
        for name in reversed(cls.created_databases):
            cls.psql(f'DROP DATABASE "{name}" WITH (FORCE);')
        for name in reversed(cls.created_roles):
            cls.psql(f'DROP ROLE "{name}";')

    @classmethod
    def psql(cls, sql, database=None):
        env = dict(cls.environment)
        if database:
            env["PGDATABASE"] = "rota_restore_test_" + database
        result = subprocess.run(["psql", "-X", "-w", "-At", "--set=ON_ERROR_STOP=1"],
                                input=sql, text=True, capture_output=True, env=env)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.psql("""
            DROP SCHEMA public CASCADE;
            CREATE SCHEMA public;
            GRANT USAGE, CREATE ON SCHEMA public TO portal_owner;
            GRANT USAGE ON SCHEMA public TO restore_reader;
            SET ROLE portal_owner;
            CREATE TABLE public.old_table (id int);
            INSERT INTO public.old_table VALUES (7);
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO restore_reader;
        """, "target")

    def restore(self, extra="", database="target", owner="portal_owner", app="portal_user", blob=True):
        with tempfile.TemporaryDirectory() as work:
            env = {**self.environment, "PGDATABASE": "rota_restore_test_" + database,
                   "RESTORE_TEST_ARCHIVE": str(self.archive), "WORK_DIR": work}
            code = '''source "$1"
work_dir="$WORK_DIR"
BLOB_NAME=fixture.backup
TARGET_ENVIRONMENT=demo
TARGET_SUBSCRIPTION=00000000-0000-0000-0000-000000000001
az() { cp "$RESTORE_TEST_ARCHIVE" "$work_dir/dump.backup"; }
prepare_dump
''' + extra + '\nrebuild_schema "$2" "$3" "$4"'
            return subprocess.run(["bash", "-c", code, "test",
                                   str(SCRIPTS / "restore-anonymised-database.sh"), owner, app,
                                   "true" if blob else "false"],
                                  env=env, text=True, capture_output=True)

    def test_restore_replaces_data_and_preserves_target_grants(self):
        self.assertGreater(self.archive.stat().st_size, 16 * 1024 * 1024)
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.psql("SELECT value FROM new_table", "target"), "synthetic")
        self.assertEqual(self.psql("SELECT to_regclass('public.old_table') IS NULL", "target"), "t")
        self.assertEqual(self.psql("SELECT tableowner FROM pg_tables WHERE tablename='new_table'", "target"),
                         "portal_owner")
        for role, privilege in (("portal_user", "INSERT"), ("restore_reader", "SELECT")):
            self.assertEqual(self.psql(f"SELECT has_table_privilege('{role}', 'new_table', '{privilege}')",
                                       "target"), "t")
        self.assertEqual(self.psql("SELECT has_table_privilege('production_only', 'new_table', 'SELECT')",
                                   "target"), "f")
        self.assertEqual(self.psql("SELECT has_sequence_privilege('portal_user', 'new_table_id_seq', 'USAGE')",
                                   "target"), "t")

    def test_sql_error_rolls_back_original_schema_and_data(self):
        result = self.restore('pg_restore() { command pg_restore "$@"; printf "SELECT 1/0;\\n"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.psql("SELECT id FROM old_table", "target"), "7")
        self.assertEqual(self.psql("SELECT to_regclass('public.new_table') IS NULL", "target"), "t")

    def test_configured_extensions_survive_schema_rebuild(self):
        self.psql("CREATE EXTENSION pg_stat_statements; CREATE EXTENSION pg_buffercache;", "target")
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.psql("SELECT count(*) FROM pg_extension "
                                   "WHERE extname IN ('pg_stat_statements','pg_buffercache')", "target"), "2")

    def test_producer_failure_at_end_of_archive_also_rolls_back(self):
        result = self.restore('pg_restore() { command pg_restore "$@"; return 7; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.psql("SELECT id FROM old_table", "target"), "7")

    def test_encrypted_file_is_rejected_during_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            encrypted = Path(directory) / "encrypted.backup.enc"
            encrypted.write_bytes(b"Salted__" + b"x" * 128)
            with patch.object(self, "archive", encrypted):
                result = self.restore()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.psql("SELECT id FROM old_table", "target"), "7")

    def test_optimiser_reset_keeps_database_and_allows_future_flyway_tables(self):
        self.psql("""
            GRANT USAGE, CREATE ON SCHEMA public TO optimiser_owner;
            SET ROLE optimiser_owner;
            CREATE TABLE IF NOT EXISTS old_jobs (id int);
        """, "optimiser")
        result = self.restore(database="optimiser", owner="optimiser_owner", app="optimiser_user", blob=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.psql("SELECT count(*) FROM pg_tables WHERE schemaname='public'", "optimiser"), "0")
        self.psql("SET ROLE optimiser_owner; CREATE TABLE flyway_fixture (id int);", "optimiser")
        self.assertEqual(self.psql("SELECT has_table_privilege('optimiser_user','flyway_fixture','INSERT')",
                                   "optimiser"), "t")


class FixtureSafetyTests(unittest.TestCase):
    def test_existing_names_are_refused_without_destructive_cleanup(self):
        for conflict in ("role:portal_owner", "database:rota_restore_test_source"):
            with self.subTest(conflict=conflict):
                with patch.object(PostgreSQLRestoreTests, "psql", return_value=conflict) as psql:
                    with self.assertRaisesRegex(RuntimeError, "refusing to change"):
                        PostgreSQLRestoreTests.check_fixture_names_available()
                self.assertEqual(psql.call_count, 1)
                self.assertNotIn("DROP", psql.call_args.args[0])

    def test_cleanup_drops_only_successfully_created_fixtures(self):
        with patch.object(PostgreSQLRestoreTests, "created_databases", ["created_database"], create=True), \
             patch.object(PostgreSQLRestoreTests, "created_roles", ["created_role"], create=True), \
             patch.object(PostgreSQLRestoreTests, "psql") as psql:
            PostgreSQLRestoreTests.cleanup_owned_fixtures()
        self.assertEqual([call.args[0] for call in psql.call_args_list], [
            'DROP DATABASE "created_database" WITH (FORCE);',
            'DROP ROLE "created_role";',
        ])


if __name__ == "__main__":
    unittest.main()
