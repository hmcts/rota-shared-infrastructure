"""Offline checks for partial shutdown recovery and transactional restore failure."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("workloads", SCRIPTS / "restore-workloads.py")
WORKLOADS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKLOADS)


def resource(kind, name, spec, annotations=None, namespace="rota"):
    return {"kind": kind, "metadata": {"name": name, "namespace": namespace,
            "uid": f"{kind}-{name}", "annotations": annotations or {}}, "spec": spec}


class ClusterAPI:
    def __init__(self):
        self.resources = {
            context: [
                resource("Kustomization", "rota", {"suspend": False}, namespace="flux-system"),
                resource("HelmRelease", "rota-resource", {"suspend": True}),
                resource("CronJob", "rota-maintenance", {"suspend": False}),
                resource("ScaledJob", "rota-worker", {}, {WORKLOADS.PAUSED: "false"}),
                resource("ScaledObject", "rota-resource", {}, {WORKLOADS.PAUSED_REPLICAS: "3"}),
                resource("Deployment", "rota-resource-java", {"replicas": 3}),
                resource("Deployment", "rota-optimiser-java", {"replicas": 1}),
                resource("StatefulSet", "already-stopped", {"replicas": 0}),
            ] for context in ("cluster-00", "cluster-01")
        }
        self.locks = {}
        self.mutations = []
        self.rollouts = []
        self.failure = None
        self.rollout_failure = None
        self.events = []

    def snapshot(self, context):
        self.events.append(("snapshot", context))
        saved = []
        for obj in self.resources[context]:
            annotations = set(obj["metadata"]["annotations"])
            if obj["kind"] in ("Kustomization", "HelmRelease"):
                annotations.add(WORKLOADS.RECONCILE)
            if obj["kind"] in ("ScaledObject", "ScaledJob"):
                annotations.add(WORKLOADS.PAUSED)
            saved.append(WORKLOADS.record(obj, obj["spec"].keys(), annotations))
        return {"context": context, "resources": saved}

    def get(self, context, namespace, name):
        if name in ("jobs", "pods"):
            return {"items": []}
        kind, name = name.split("/")
        obj = copy.deepcopy(next(obj for obj in self.resources[context]
                                 if obj["kind"] == kind and obj["metadata"]["name"] == name))
        if kind in ("ScaledObject", "ScaledJob"):
            obj["status"] = {"conditions": [{"type": "Paused", "status": "True"}]}
        return obj

    def patch(self, context, saved, changes, dry_run=False):
        if dry_run:
            return
        if self.failure == (context, saved["name"]):
            self.failure = None
            raise RuntimeError("injected patch failure")
        obj = next(obj for obj in self.resources[context]
                   if obj["kind"] == saved["kind"] and obj["metadata"]["name"] == saved["name"])
        obj["spec"].update(changes.get("spec", {}))
        for key, value in changes.get("metadata", {}).get("annotations", {}).items():
            if value is None:
                obj["metadata"]["annotations"].pop(key, None)
            else:
                obj["metadata"]["annotations"][key] = value
        self.mutations.append((context, saved["name"], changes))
        self.events.append(("patch", context, saved["name"]))

    def kubectl(self, context, namespace, *args, **kwargs):
        if args[:2] == ("create", "configmap"):
            if context in self.locks:
                raise RuntimeError("restore lock already exists")
            self.locks[context] = {"data": {"run-id": args[3].split("=", 2)[2]}}
            self.events.append(("lock", context))
        elif args[:2] == ("patch", "configmap/" + WORKLOADS.LOCK):
            self.locks[context]["data"].update(json.loads(args[args.index("-p") + 1])["data"])
            self.events.append(("persist", context))
        elif args[0] == "get":
            lock = self.locks.get(context)
            return json.dumps(lock) if lock else ""
        elif args[:2] == ("delete", "configmap"):
            self.locks.pop(context)
        elif args[:2] == ("rollout", "status"):
            self.rollouts.append((context, args[2]))
            self.events.append(("ready", context, args[2]))
            if self.rollout_failure == (context, args[2]):
                raise RuntimeError("injected optimiser readiness failure")
        else:
            raise AssertionError(args)


class WorkloadRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name) / "workloads.json"
        self.api = ClusterAPI()
        self.original = copy.deepcopy(self.api.resources)
        for name in ("get", "patch", "snapshot", "kubectl"):
            mock = patch.object(WORKLOADS, name, getattr(self.api, name))
            mock.start()
            self.addCleanup(mock.stop)

    def stop(self):
        WORKLOADS.stop(self.state, list(self.api.resources), "123-1", 1)

    def test_two_clusters_recover_exact_settings_and_optimiser_first(self):
        self.stop()
        for objects in self.api.resources.values():
            for obj in objects:
                if "replicas" in obj["spec"]:
                    self.assertEqual(obj["spec"]["replicas"], 0)
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.resources, self.original)
        self.assertEqual(self.api.locks, {})
        for context in self.api.resources:
            rollouts = [name for cluster, name in self.api.rollouts if cluster == context]
            self.assertEqual(rollouts[0], "Deployment/rota-optimiser-java")
            self.assertNotIn("StatefulSet/already-stopped", rollouts)
        mutations = len(self.api.mutations)
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(len(self.api.mutations), mutations)

    def test_preflight_failure_in_second_cluster_changes_neither(self):
        def snapshot(context):
            if context == "cluster-01":
                raise RuntimeError("missing access")
            return self.api.snapshot(context)
        with patch.object(WORKLOADS, "snapshot", snapshot), self.assertRaises(RuntimeError):
            self.stop()
        self.assertEqual(self.api.resources, self.original)
        WORKLOADS.resume(self.state, 1)
        self.assertFalse(self.api.locks)
        self.assertFalse(self.api.mutations)

    def test_both_locks_precede_snapshots_and_both_snapshots_precede_shutdown(self):
        self.stop()
        events = self.api.events
        first_snapshot = next(i for i, event in enumerate(events) if event[0] == "snapshot")
        first_patch = next(i for i, event in enumerate(events) if event[0] == "patch")
        self.assertEqual([event[1] for event in events[:first_snapshot] if event[0] == "lock"],
                         ["cluster-00", "cluster-01"])
        self.assertEqual({event[1] for event in events[:first_patch] if event[0] == "persist"},
                         {"cluster-00", "cluster-01"})
        for lock in self.api.locks.values():
            snapshot = json.loads(lock["data"]["workload-state"])
            self.assertTrue(snapshot["resources"])
            self.assertTrue(snapshot["shutdown_started"])

    def test_another_run_prevents_snapshots_of_its_stopped_replicas(self):
        for context, resources in self.api.resources.items():
            self.api.locks[context] = {"data": {"run-id": "first-run"}}
            for obj in resources:
                if "replicas" in obj["spec"]:
                    obj["spec"]["replicas"] = 0
        before = copy.deepcopy(self.api.resources)
        with patch.object(WORKLOADS, "snapshot") as snapshot:
            with self.assertRaisesRegex(RuntimeError, "already exists"):
                self.stop()
            snapshot.assert_not_called()
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.resources, before)
        self.assertEqual({lock["data"]["run-id"] for lock in self.api.locks.values()}, {"first-run"})

    def test_snapshot_publication_failure_releases_locks_without_changing_workloads(self):
        def fail_publication(context, namespace, *args, **kwargs):
            if args[0] == "patch":
                raise RuntimeError("cannot publish snapshot")
            return self.api.kubectl(context, namespace, *args, **kwargs)
        with patch.object(WORKLOADS, "kubectl", fail_publication):
            with self.assertRaisesRegex(RuntimeError, "cannot publish snapshot"):
                self.stop()
        WORKLOADS.resume(self.state, 1)
        self.assertFalse(self.api.mutations)
        self.assertFalse(self.api.locks)
        self.assertEqual(self.api.resources, self.original)

    def test_optimisers_in_both_clusters_are_ready_before_any_consumer(self):
        self.stop()
        self.api.events.clear()
        WORKLOADS.resume(self.state, 1)
        first_consumer = next(i for i, event in enumerate(self.api.events)
                              if event[0] == "patch" and event[2] == "rota-resource-java")
        ready = [event for event in self.api.events[:first_consumer] if event[0] == "ready"]
        self.assertEqual(ready, [
            ("ready", "cluster-00", "Deployment/rota-optimiser-java"),
            ("ready", "cluster-01", "Deployment/rota-optimiser-java"),
        ])

    def test_zero_replicas_in_first_cluster_waits_for_second_cluster_optimiser(self):
        for obj in self.api.resources["cluster-00"]:
            if obj["metadata"]["name"] == "rota-optimiser-java":
                obj["spec"]["replicas"] = 0
        self.original = copy.deepcopy(self.api.resources)
        self.stop()
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.rollouts[0], ("cluster-01", "Deployment/rota-optimiser-java"))
        self.assertEqual(self.api.resources, self.original)

    def test_both_optimisers_stopped_is_rejected_before_workload_changes(self):
        for resources in self.api.resources.values():
            for obj in resources:
                if obj["metadata"]["name"] == "rota-optimiser-java":
                    obj["spec"]["replicas"] = 0
        with self.assertRaisesRegex(RuntimeError, "Both optimisers have zero replicas"):
            self.stop()
        WORKLOADS.resume(self.state, 1)
        self.assertFalse(self.api.mutations)
        self.assertFalse(self.api.rollouts)
        self.assertFalse(self.api.locks)

    def test_optimiser_readiness_failure_keeps_all_consumers_stopped_and_can_retry(self):
        self.stop()
        self.api.rollout_failure = ("cluster-01", "Deployment/rota-optimiser-java")
        with self.assertRaisesRegex(RuntimeError, "readiness failure"):
            WORKLOADS.resume(self.state, 1)
        for resources in self.api.resources.values():
            consumer = next(obj for obj in resources if obj["metadata"]["name"] == "rota-resource-java"
                            and obj["kind"] == "Deployment")
            self.assertEqual(consumer["spec"]["replicas"], 0)
        self.assertEqual(len(self.api.locks), 2)
        self.api.rollout_failure = None
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.resources, self.original)
        self.assertFalse(self.api.locks)

    def test_recovery_retry_uses_an_already_resumed_optimiser_without_repatching_its_cluster(self):
        self.stop()
        self.api.failure = ("cluster-01", "rota-resource-java")
        with self.assertRaisesRegex(RuntimeError, "injected patch failure"):
            WORKLOADS.resume(self.state, 1)
        self.assertNotIn("cluster-00", self.api.locks)
        previous_mutations = len(self.api.mutations)
        WORKLOADS.resume(self.state, 1)
        self.assertFalse(any(context == "cluster-00"
                             for context, *_ in self.api.mutations[previous_mutations:]))
        self.assertEqual(self.api.resources, self.original)
        self.assertFalse(self.api.locks)

    def test_mid_shutdown_failure_can_restore_both_clusters(self):
        self.api.failure = ("cluster-01", "rota-resource-java")
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.stop()
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.resources, self.original)
        self.assertFalse(self.api.locks)

    def test_other_runs_lock_is_never_removed(self):
        self.api.locks["cluster-01"] = {"data": {"run-id": "other"}}
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.stop()
        WORKLOADS.resume(self.state, 1)
        self.assertEqual(self.api.locks, {"cluster-01": {"data": {"run-id": "other"}}})
        self.assertEqual(self.api.resources, self.original)

    def test_replaced_workload_is_not_modified_during_recovery(self):
        self.stop()
        self.api.resources["cluster-00"][-1]["metadata"]["uid"] = "replacement"
        before = len(self.api.mutations)
        with self.assertRaisesRegex(RuntimeError, "replaced"):
            WORKLOADS.resume(self.state, 1)
        self.assertFalse(any(context == "cluster-00" for context, *_ in self.api.mutations[before:]))
        self.assertIn("cluster-00", self.api.locks)

    def test_missing_recovery_record_is_a_noop(self):
        WORKLOADS.resume(self.state, 1)
        self.assertFalse(self.api.mutations)


class ShellRestoreTests(unittest.TestCase):
    def run_shell(self, code):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(
                ["bash", "-c", 'source "$1"; work_dir="$2"; state_dir="$2/state"; ' + code,
                 "test", str(SCRIPTS / "restore-anonymised-database.sh"), directory],
                capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )

    def test_pg_restore_failure_never_emits_commit(self):
        result = self.run_shell('pg_restore() { echo "SELECT 42;"; return 5; }; '
                                'psql() { cat; }; rebuild_schema portal_owner portal_user true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BEGIN;", result.stdout)
        self.assertNotIn("COMMIT;", result.stdout)

    def test_archive_listing_reads_a_large_regular_file_without_a_pipe(self):
        result = self.run_shell('python3 -c \'import sys; open(sys.argv[1], "wb").write(b"x" * 8388608)\' '
                                '"$work_dir/dump.backup"; '
                                'pg_restore() { [[ $1 == --list && -f $2 ]] || return 99; '
                                'printf "%s\\n" "1; 0 0 TABLE public fixture owner"; }; '
                                'prepare_restore_list; test -s "$work_dir/restore.list"')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_optimiser_rebuild_commits_without_reading_blob(self):
        result = self.run_shell('pg_restore() { echo SHOULD_NOT_READ_ARCHIVE; return 99; }; psql() { cat; }; '
                                'rebuild_schema optimiser_owner optimiser_user false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("COMMIT;", result.stdout)
        self.assertNotIn("SHOULD_NOT_READ_ARCHIVE", result.stdout)

    def test_incomplete_database_restore_does_not_restart(self):
        result = self.run_shell('mkdir -p "$state_dir"; touch "$state_dir/database-started"; '
                                'python3() { echo SHOULD_NOT_RESTART; }; cleanup')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_RESTART", result.stdout)
        self.assertIn("remain stopped", result.stderr)

    def test_production_target_rejected_before_any_azure_call(self):
        result = self.run_shell('TARGET_ENVIRONMENT=prod; az() { echo SHOULD_NOT_CALL_AZURE; }; validate_inputs')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SHOULD_NOT_CALL_AZURE", result.stdout)

    def test_decrypted_backup_requires_no_encryption_password(self):
        setup = (
            'TARGET_ENVIRONMENT=perftest; BLOB_NAME=fixture.backup; '
            'TARGET_SUBSCRIPTION=00000000-0000-0000-0000-000000000001; '
            'AKS_SUBSCRIPTION=00000000-0000-0000-0000-000000000002; '
            'az() { echo SHOULD_NOT_CALL_AZURE; }; '
            'kubectl() { :; }; kubelogin() { :; }; psql() { :; }; '
            'pg_restore() { echo "pg_restore (PostgreSQL) 15.20"; }; '
        )
        result = self.run_shell(setup + 'unset ENCPASSWORD; validate_inputs')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('SHOULD_NOT_CALL_AZURE', result.stdout)


if __name__ == "__main__":
    unittest.main()
