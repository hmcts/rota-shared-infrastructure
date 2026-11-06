"""Exercise the pipeline script with fake Azure/PostgreSQL tools; no cloud access."""

import base64
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/anonymise-database.sh"
SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
REAL_OPENSSL = shutil.which("openssl")
DUMP_CONTENT = b"PGDMP" + b"synthetic archive data\n" * 100000
SENSITIVE_MARKERS = (
    "confidential-stdout-record", "confidential-stderr-record", "confidential-report-record",
    "confidential-client-error", "unexpectedSensitiveOutput",
)

MOCK_TOOL = r'''
import base64
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["MOCK_ROOT"])
scenario = os.environ.get("MOCK_SCENARIO", "")
clone = "rota-dapdb-anon-12345-1"
source = "rota-psql-dapdb-prod"

def value(flag):
    for i, arg in enumerate(args):
        if arg == flag:
            return args[i + 1]
        if arg.startswith(flag + "="):
            return arg.split("=", 1)[1]
    raise AssertionError("Missing " + flag)

if "--version" in args:
    print(tool + " (PostgreSQL) " + ("14.1" if scenario == "wrong_client" else "15.8"))
    sys.exit(0)

with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([tool] + args) + "\n")

if tool == "flock":
    fcntl.flock(int(args[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
elif tool == "curl":
    if scenario == "download_failure":
        sys.exit(22)
    shutil.copyfile(root / "package.tar.gz", value("--output"))
elif tool == "openssl":
    assert "-aes-256-ctr" in args and "-pbkdf2" in args and "-salt" in args
    assert value("-iter") == "600000"
    assert value("-md") == "sha512"
    assert value("-pass") == "env:ENCPASSWORD"
    assert os.environ["ENCPASSWORD"] == "fake-encryption-password"
    if os.environ.get("USE_REAL_OPENSSL") == "true":
        sys.exit(subprocess.run([os.environ["REAL_OPENSSL"]] + args).returncode)
    if "-d" in args:
        if scenario == "decryption_failure":
            sys.exit(10)
        encrypted = Path(value("-in")).read_bytes()
        assert encrypted.startswith(b"MOCKENC:")
        sys.stdout.buffer.write(base64.b64decode(encrypted[len(b"MOCKENC:"):]))
    else:
        plaintext = Path(value("-in")).read_bytes() if "-in" in args else sys.stdin.buffer.read()
        destination = Path(value("-out"))
        failed_encryption = (
            (scenario == "encryption_failure" and destination.name.endswith(".backup.enc"))
            or (scenario == "diagnostics_encryption_failure" and destination.name.endswith(".log.enc"))
            or (scenario == "checks_encryption_failure" and destination.name.endswith(".csv.enc"))
        )
        if failed_encryption:
            destination.write_bytes(b"partial encrypted output")
            print("confidential-client-error", file=sys.stderr)
            sys.exit(9)
        destination.write_bytes(b"MOCKENC:" + base64.b64encode(plaintext))
elif tool == "az":
    command = args[:3]
    if args[:2] == ["account", "set"]:
        assert value("--subscription") == "11111111-1111-1111-1111-111111111111"
    elif command == ["keyvault", "secret", "show"]:
        secrets = {
            "dapdb-postgresql-fqdn": source + ".postgres.database.azure.com",
            "dapdb-postgresql-admin-username": "pgadmin",
            "dapdb-postgresql-admin-password": "fake-admin-password",
            "moj-user-password": "fake-owner-password",
            "anonymised-db-dump-encryption-password": "fake-encryption-password",
        }
        if scenario == "wrong_source":
            secrets["dapdb-postgresql-fqdn"] = "legacy.postgres.database.azure.com"
        if scenario == "missing_encryption_secret" and value("--name") == "anonymised-db-dump-encryption-password":
            sys.exit(11)
        if scenario == "empty_encryption_secret":
            secrets["anonymised-db-dump-encryption-password"] = ""
        print(secrets[value("--name")])
    elif command == ["postgres", "flexible-server", "list"]:
        if scenario == "preexisting" or (root / "clone").exists():
            print(clone)
    elif command == ["postgres", "flexible-server", "show"]:
        if value("--query") == "id":
            assert value("--name") == source
            print("/subscriptions/mock/resourceGroups/rota-shared-infra-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/" + source)
        else:
            assert value("--name") == clone
            print((source if scenario == "wrong_clone_host" else clone) + ".postgres.database.azure.com")
    elif command == ["postgres", "flexible-server", "restore"]:
        assert value("--name") == clone
        assert value("--source-server").endswith("/" + source)
        (root / "clone").touch()
        if scenario == "restore_failure":
            sys.exit(4)
    elif command == ["postgres", "flexible-server", "delete"]:
        assert value("--name") == clone
        if scenario == "cleanup_failure":
            sys.exit(5)
        (root / "clone").unlink()
    elif command == ["storage", "blob", "upload"]:
        assert value("--account-name") == "rotasaprod"
        assert value("--container-name") == "anonymised-db-dumps"
        assert value("--auth-mode") == "login"
        assert value("--overwrite") == "false"
        assert value("--if-none-match") == "*"
        assert (root / "anonymised").exists()
        assert (root / "archive_validated").exists()
        assert value("--name").endswith(".backup.enc")
        encrypted = Path(value("--file")).read_bytes()
        assert encrypted.startswith((b"MOCKENC:", b"Salted__"))
        assert not list((root / "rota-anonymise-12345-1").rglob("*.backup"))
        if scenario == "upload_failure":
            sys.exit(6)
        (root / "remote_size").write_text(str(Path(value("--file")).stat().st_size))
        (root / "uploaded.enc").write_bytes(encrypted)
    elif command == ["storage", "blob", "show"]:
        print("0" if scenario == "wrong_size" else (root / "remote_size").read_text())
    else:
        raise AssertionError(args)
elif tool == "psql":
    assert value("--host") == clone + ".postgres.database.azure.com"
    print("confidential-client-error", file=sys.stderr)
elif tool == "pg_dump":
    assert value("--host") == clone + ".postgres.database.azure.com"
    assert value("--schema") == "public"
    assert value("--dbname") == "mojdb"
    assert "-Fc" in args
    assert os.environ["PGPASSWORD"] == "fake-admin-password"
    assert not Path(os.environ["ANONYMISATION_CHECKS_FILE"]).exists()
    for artifact in (root / "rota-anonymise-12345-1/checks").iterdir():
        assert artifact.name.endswith(".enc")
        assert artifact.read_bytes().startswith((b"MOCKENC:", b"Salted__"))
    if scenario == "dump_failure":
        print("confidential-client-error", file=sys.stderr)
        sys.stdout.buffer.write(b"PGDMP incomplete dump")
        sys.exit(7)
    if scenario == "empty_dump":
        sys.exit(0)
    assert not any(arg.startswith("--file") for arg in args)
    assert "ENCPASSWORD" not in os.environ
    sys.stdout.buffer.write(b"PGDMP" + b"synthetic archive data\n" * 100000)
elif tool == "pg_restore":
    assert args == ["--list"]
    # Deliberately read only the archive header. The script must drain the rest
    # of a large stream, otherwise OpenSSL fails with a broken pipe.
    assert sys.stdin.buffer.read(5) == b"PGDMP"
    if scenario == "invalid_dump":
        print("confidential-client-error", file=sys.stderr)
        sys.exit(8)
    (root / "archive_validated").touch()
else:
    raise AssertionError(tool)
'''

ANONYMISER = r'''#!/usr/bin/env bash
set -euo pipefail
[[ $1 == rota-dapdb-anon-12345-1.postgres.database.azure.com && $PGHOST == "$1" ]]
[[ $PGDATABASE == mojdb && $PGSSLMODE == require ]]
if [[ $PGUSER == moj_user ]]; then
  [[ $PGPASSWORD == fake-owner-password ]]
else
  [[ $PGUSER == pgadmin && $PGPASSWORD == fake-admin-password ]]
fi
touch "$MOCK_ROOT/anonymised"
printf 'confidential-stdout-record\n'
printf 'confidential-stderr-record %s\n' "$PGPASSWORD" >&2
printf '##vso[task.setvariable variable=unexpectedSensitiveOutput]confidential-stdout-record\n'
if [[ ${MOCK_SCENARIO:-} != missing_report ]]; then
  printf 'check,result\nexample,passed\nconfidential-report-record,private\n' > "$ANONYMISATION_CHECKS_FILE"
fi
if [[ ${MOCK_SCENARIO:-} == interrupted ]]; then
  sleep 60
fi
[[ ${MOCK_SCENARIO:-} != anonymisation_failure ]]
'''


class AnonymiseDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("az", "curl", "flock", "openssl", "psql", "pg_dump", "pg_restore"):
            path = self.bin / tool
            path.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
            path.chmod(0o755)
        with tarfile.open(self.root / "package.tar.gz", "w:gz") as archive:
            payload = ANONYMISER.encode()
            entry = tarfile.TarInfo("rota_anonymisation")
            entry.mode = 0o755
            entry.size = len(payload)
            archive.addfile(entry, io.BytesIO(payload))
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "MOCK_ROOT": str(self.root),
            "RUN_ID": "12345-1",
            "AGENT_TEMPDIRECTORY": str(self.root),
            "PRODUCTION_SUBSCRIPTION_ID": SUBSCRIPTION,
            "PITR_TIMESTAMP": "2026-10-29T10:00:00Z",
            "ANONYMISATION_VERSION": "1.2.3",
            "REPOSITORY_URL": "https://example.invalid/artifactory/repocentral",
            "POSTGRESQL_HOME": str(self.root),
            "ANONYMISATION_CHECKS_FILE": str(self.root / "checks.csv"),
            "ARTIFACTORY_TOKEN": "$(rotaAnonymisationArtifactoryToken)",
            "PUBLISH_DUMP": "false",
            "USE_REAL_OPENSSL": "false",
        }
        self.work = self.root / "rota-anonymise-12345-1"

    def run_script(self, scenario="", mode="run", trace=False, **overrides):
        result = subprocess.run(
            ["bash", *(["-x"] if trace else []), str(SCRIPT), mode],
            env={**self.env, "MOCK_SCENARIO": scenario, **overrides},
            text=True, capture_output=True, timeout=15,
        )
        self.assertNotIn("fake-admin-password", result.stdout + result.stderr)
        self.assertNotIn("fake-owner-password", result.stdout + result.stderr)
        self.assertNotIn("fake-encryption-password", result.stdout + result.stderr)
        for marker in SENSITIVE_MARKERS:
            self.assertNotIn(marker, result.stdout + result.stderr)
        if result.returncode != 0:
            self.assertFalse((self.work / "checks").exists())
            self.assertNotIn("anonymisationChecksAvailable]true", result.stdout)
        return result

    def commands(self):
        log = self.root / "commands.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def called(self, *prefix):
        return any(command[:len(prefix)] == list(prefix) for command in self.commands())

    def assert_clean(self):
        self.assertFalse((self.root / "clone").exists())
        self.assertFalse((self.work / "work").exists())
        self.assertFalse((self.root / "checks.csv").exists())

    def decrypt_fixture_artifact(self, path):
        content = path.read_bytes()
        self.assertTrue(content.startswith(b"MOCKENC:"))
        return base64.b64decode(content[len(b"MOCKENC:"):])

    def assert_encrypted_reports(self, decrypt):
        artifacts = self.work / "checks"
        self.assertEqual(
            {path.name for path in artifacts.iterdir()},
            {"rota_anonymised_database_checks_12345-1.csv.enc", "anonymisation_12345-1.log.enc"},
        )
        for path in artifacts.iterdir():
            for marker in SENSITIVE_MARKERS:
                self.assertNotIn(marker.encode(), path.read_bytes())
        report = decrypt(artifacts / "rota_anonymised_database_checks_12345-1.csv.enc")
        self.assertIn(b"confidential-report-record", report)
        diagnostics = decrypt(artifacts / "anonymisation_12345-1.log.enc")
        self.assertIn(b"confidential-stdout-record", diagnostics)
        self.assertIn(b"confidential-stderr-record", diagnostics)
        self.assertIn(b"fake-admin-password", diagnostics)

    def test_validation_run_retains_checks_without_upload(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.called("pg_dump"))
        self.assertFalse(self.called("az", "storage", "blob", "upload"))
        self.assert_encrypted_reports(self.decrypt_fixture_artifact)
        self.assertIn("anonymisationChecksAvailable]true", result.stdout)
        self.assert_clean()

    def test_publish_uploads_and_verifies_then_cleans(self):
        result = self.run_script(PUBLISH_DUMP="True")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.called("az", "storage", "blob", "upload"))
        self.assertTrue(self.called("az", "storage", "blob", "show"))
        self.assertIn("https://rotasaprod.blob.core.windows.net/anonymised-db-dumps/", result.stdout)
        self.assert_clean()

    def test_shell_tracing_cannot_expose_credentials_or_data(self):
        result = self.run_script(trace=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_encrypted_reports(self.decrypt_fixture_artifact)
        self.assert_clean()

    def test_owner_credentials_can_differ_from_dump_admin(self):
        result = self.run_script(ANONYMISATION_USER="moj_user", ANONYMISATION_PASSWORD_SECRET="moj-user-password")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean()

    def test_failures_never_upload_and_still_clean(self):
        for scenario in (
            "missing_encryption_secret", "empty_encryption_secret", "download_failure",
            "restore_failure", "anonymisation_failure", "missing_report", "dump_failure",
            "empty_dump", "encryption_failure", "decryption_failure", "invalid_dump",
            "diagnostics_encryption_failure", "checks_encryption_failure",
        ):
            with self.subTest(scenario=scenario):
                # Each scenario needs a fresh workspace and run directory.
                fixture = AnonymiseDatabaseTests()
                fixture.setUp()
                try:
                    result = fixture.run_script(scenario, PUBLISH_DUMP="true")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(fixture.called("az", "storage", "blob", "upload"))
                    fixture.assert_clean()
                finally:
                    fixture.doCleanups()

    def test_failed_anonymisation_discards_report_and_does_not_dump(self):
        result = self.run_script("anonymisation_failure", PUBLISH_DUMP="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called("pg_dump"))
        self.assertFalse((self.work / "checks").exists())
        self.assert_clean()

    def test_upload_failure_cleans_server_and_local_dump(self):
        result = self.run_script("upload_failure", PUBLISH_DUMP="true")
        self.assertNotEqual(result.returncode, 0)
        self.assert_clean()

    def test_wrong_remote_size_fails_run(self):
        result = self.run_script("wrong_size", PUBLISH_DUMP="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("size does not match", result.stderr)
        self.assert_clean()

    def test_wrong_source_never_restores_or_deletes(self):
        result = self.run_script("wrong_source")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called("az", "postgres", "flexible-server", "restore"))
        self.assertFalse(self.called("az", "postgres", "flexible-server", "delete"))

    def test_preexisting_clone_is_never_deleted(self):
        result = self.run_script("preexisting")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called("az", "postgres", "flexible-server", "delete"))

    def test_production_hostname_is_rejected_as_anonymisation_target(self):
        result = self.run_script("wrong_clone_host", PUBLISH_DUMP="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called("psql"))
        self.assertFalse((self.root / "anonymised").exists())
        self.assert_clean()

    def test_stale_checks_report_cannot_allow_publication(self):
        (self.root / "checks.csv").write_text("old report from a previous run")
        result = self.run_script("missing_report", PUBLISH_DUMP="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called("pg_dump"))
        self.assertFalse(self.called("az", "storage", "blob", "upload"))
        self.assert_clean()

    def test_wrong_client_fails_before_cloud_access(self):
        result = self.run_script("wrong_client")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_invalid_run_id_fails_before_cloud_access(self):
        result = self.run_script(RUN_ID="../../production")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_invalid_subscription_fails_before_cloud_access(self):
        result = self.run_script(PRODUCTION_SUBSCRIPTION_ID="------------------------------------")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_cleanup_failure_is_reported_and_retry_can_finish(self):
        result = self.run_script("cleanup_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cleanup failed", result.stderr)
        self.assertTrue((self.root / "clone").exists())
        self.assertFalse((self.work / "work").exists())
        retry = self.run_script(mode="cleanup")
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assert_clean()

    def test_cleanup_without_restore_marker_does_not_delete_server(self):
        result = self.run_script(mode="cleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [])

    def test_final_cleanup_removes_successful_local_report(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / "checks").exists())
        result = self.run_script(mode="cleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.work / "checks").exists())
        self.assert_clean()

    def test_cleanup_recovers_report_from_interrupted_run(self):
        self.work.mkdir()
        (self.root / "checks.csv.lock").write_text("12345-1\n")
        (self.root / "checks.csv").write_text("unfinished report")
        result = self.run_script(mode="cleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean()

    def test_cleanup_preserves_another_runs_fixed_report(self):
        self.work.mkdir()
        (self.root / "checks.csv.lock").write_text("54321-1\n")
        (self.root / "checks.csv").write_text("another run's report")
        result = self.run_script(mode="cleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "checks.csv").read_text(), "another run's report")

    def test_termination_cleans_files_and_server_without_upload(self):
        process = subprocess.Popen(
            ["bash", str(SCRIPT)],
            env={**self.env, "MOCK_SCENARIO": "interrupted", "PUBLISH_DUMP": "true"},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not (self.root / "checks.csv").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    self.fail("Anonymisation did not reach the interruption point")
                time.sleep(0.05)
            os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=15)
            self.assertNotEqual(process.returncode, 0, stderr)
            self.assertNotIn("anonymisationChecksAvailable]true", stdout)
            for marker in SENSITIVE_MARKERS:
                self.assertNotIn(marker, stdout + stderr)
            self.assertFalse(self.called("az", "storage", "blob", "upload"))
            self.assertFalse((self.work / "checks").exists())
            self.assert_clean()
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    @unittest.skipUnless(REAL_OPENSSL, "OpenSSL is not installed")
    def test_real_openssl_round_trip_with_streamed_backup(self):
        result = self.run_script(
            USE_REAL_OPENSSL="true", REAL_OPENSSL=REAL_OPENSSL, PUBLISH_DUMP="true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        encrypted = (self.root / "uploaded.enc").read_bytes()
        self.assertTrue(encrypted.startswith(b"Salted__"))
        def decrypt(path):
            return subprocess.run(
                [REAL_OPENSSL, "enc", "-d", "-aes-256-ctr", "-pbkdf2", "-iter", "600000",
                 "-md", "sha512", "-salt", "-pass", "env:ENCPASSWORD"],
                input=path.read_bytes(), capture_output=True, check=True,
                env={**os.environ, "ENCPASSWORD": "fake-encryption-password"},
            ).stdout

        self.assertEqual(decrypt(self.root / "uploaded.enc"), DUMP_CONTENT)
        self.assert_encrypted_reports(decrypt)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
