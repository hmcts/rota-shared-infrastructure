#!/usr/bin/env python3
"""Save, stop and restore the Rota namespace in every supplied AKS context."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NAMESPACE = "rota"
LOCK = "rota-database-restore"
RECONCILE = "kustomize.toolkit.fluxcd.io/reconcile"
PAUSED = "autoscaling.keda.sh/paused"
PAUSED_REPLICAS = "autoscaling.keda.sh/paused-replicas"
OPTIMISER_DEPLOYMENT = "rota-optimiser-java"

WORKLOAD_KINDS = ("Deployment", "StatefulSet")
FLUX_KINDS = ("Kustomization", "HelmRelease")
KEDA_KINDS = ("ScaledObject", "ScaledJob")


# -----------------------------------------------------------------------------
# Kubernetes commands
# -----------------------------------------------------------------------------
def kubectl(context, namespace, *args, decode=False):
    # Rollout watches use their own --timeout rather than the HTTP request limit.
    request_timeout = "0" if args[0] == "rollout" else "60s"
    result = subprocess.run(
        [
            "kubectl",
            "--context", context,
            "--namespace", namespace,
            f"--request-timeout={request_timeout}",
            *args,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout) if decode else result.stdout


def get(context, namespace, resource):
    return kubectl(context, namespace, "get", resource, "-o", "json", decode=True)


def patch(context, resource, changes, dry_run=False):
    args = [
        "patch", f"{resource['kind']}/{resource['name']}",
        "--type=merge",
        "-p", json.dumps(changes),
    ]
    if dry_run:
        args.append("--dry-run=server")
    kubectl(context, resource["namespace"], *args)


# -----------------------------------------------------------------------------
# Recovery state and resource settings
# -----------------------------------------------------------------------------
def save(path, state):
    """Replace the recovery record atomically before changing more resources."""
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def record(obj, spec=None, annotations=None):
    """Keep only the identity and settings needed to restore this resource."""
    return {
        "kind": obj["kind"],
        "name": obj["metadata"]["name"],
        "namespace": obj["metadata"]["namespace"],
        "uid": obj["metadata"]["uid"],
        "spec": {key: obj.get("spec", {}).get(key) for key in spec or []},
        "annotations": {
            key: obj["metadata"].get("annotations", {}).get(key)
            for key in annotations or []
        },
    }


def original(resource):
    return {
        "metadata": {"annotations": resource["annotations"]},
        "spec": resource["spec"],
    }


def stopped(resource):
    kind = resource["kind"]
    if kind in WORKLOAD_KINDS:
        return {"spec": {"replicas": 0}}
    if kind == "ScaledObject":
        return {"metadata": {"annotations": {PAUSED: "true", PAUSED_REPLICAS: None}}}
    if kind == "ScaledJob":
        return {"metadata": {"annotations": {PAUSED: "true"}}}
    if kind in FLUX_KINDS:
        return {
            "metadata": {"annotations": {RECONCILE: "disabled"}},
            "spec": {"suspend": True},
        }
    return {"spec": {"suspend": True}}


# -----------------------------------------------------------------------------
# Cluster preflight checks and snapshots
# -----------------------------------------------------------------------------
def snapshot(context):
    # Discovery distinguishes an absent optional controller from an API/RBAC failure.
    available = set(kubectl(context, NAMESPACE, "api-resources", "-o", "name").split())
    resources = []
    for name, fields, annotations in (
        ("helmreleases.helm.toolkit.fluxcd.io", ["suspend"], [RECONCILE]),
        ("cronjobs.batch", ["suspend"], []),
        ("scaledobjects.keda.sh", [], [PAUSED, PAUSED_REPLICAS]),
        ("scaledjobs.keda.sh", [], [PAUSED]),
        ("deployments.apps", ["replicas"], []),
        ("statefulsets.apps", ["replicas"], []),
    ):
        if name not in available:
            if name in ("deployments.apps", "statefulsets.apps", "cronjobs.batch"):
                raise RuntimeError(f"Required API {name} unavailable in {context}")
            continue
        for obj in get(context, NAMESPACE, name)["items"]:
            resources.append(record(obj, fields, annotations))

    if "kustomizations.kustomize.toolkit.fluxcd.io" in available:
        obj = get(context, "flux-system", "kustomization/rota")
        resources.insert(0, record(obj, ["suspend"], [RECONCILE]))

    validate_cluster_resources(context, resources)
    return {"context": context, "resources": resources}


def validate_cluster_resources(context, resources):
    if not any(resource["kind"] == "Deployment" for resource in resources):
        raise RuntimeError(f"No Rota Deployments found in {context}")
    if not any(resource["name"] == "rota-optimiser-java" for resource in resources):
        raise RuntimeError(f"No optimiser Deployment found in {context}")
    if get(context, NAMESPACE, "daemonsets")["items"]:
        raise RuntimeError(f"Unexpected DaemonSets in {context}/{NAMESPACE}; review shutdown")
    for hpa in get(context, NAMESPACE, "hpa")["items"]:
        if hpa["spec"].get("minReplicas", 1) == 0:
            raise RuntimeError("HPA minReplicas=0 requires a separate maintenance policy")
    for resource in resources:
        patch(context, resource, stopped(resource), dry_run=True)
        patch(context, resource, original(resource), dry_run=True)


# -----------------------------------------------------------------------------
# Controller and workload readiness checks
# -----------------------------------------------------------------------------
def wait_until(check, description, timeout):
    deadline = time.monotonic() + timeout
    while not check():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for {description}")
        time.sleep(5)


def active_pods(context):
    return [
        pod for pod in get(context, NAMESPACE, "pods")["items"]
        if pod.get("status", {}).get("phase") not in ("Succeeded", "Failed")
    ]


def reconciliation_finished(context, resource):
    obj = get(context, resource["namespace"], f"{resource['kind']}/{resource['name']}")
    conditions = obj.get("status", {}).get("conditions", [])
    return not any(
        condition["type"] == "Reconciling" and condition["status"] == "True"
        for condition in conditions
    )


def autoscaling_paused(context, resource):
    obj = get(context, NAMESPACE, f"{resource['kind']}/{resource['name']}")
    conditions = obj.get("status", {}).get("conditions", [])
    return any(
        condition["type"] == "Paused" and condition["status"] == "True"
        for condition in conditions
    )


def jobs_finished(context):
    jobs = get(context, NAMESPACE, "jobs")["items"]
    return not any(job.get("status", {}).get("active", 0) for job in jobs)


def wait_for_controllers(context, resources, timeout):
    for resource in resources:
        if resource["kind"] in FLUX_KINDS:
            wait_until(
                lambda: reconciliation_finished(context, resource),
                f"{resource['name']} reconciliation to finish",
                timeout,
            )
        elif resource["kind"] in KEDA_KINDS:
            wait_until(
                lambda: autoscaling_paused(context, resource),
                f"{resource['name']} autoscaling to pause",
                timeout,
            )


# -----------------------------------------------------------------------------
# Restore locks and workload shutdown
# -----------------------------------------------------------------------------
def acquire_restore_locks(path, state):
    for cluster in state["clusters"]:
        kubectl(
            cluster["context"], NAMESPACE,
            "create", "configmap", LOCK,
            f"--from-literal=run-id={state['run_id']}",
        )
        cluster["locked"] = True
        save(path, state)


def persist_cluster_snapshot(cluster):
    # The lock also carries recovery settings if the agent loses its local files.
    kubectl(
        cluster["context"], NAMESPACE,
        "patch", f"configmap/{LOCK}", "--type=merge",
        "-p", json.dumps({"data": {"workload-state": json.dumps(cluster)}}),
    )


def optimiser_workload(cluster):
    for resource in cluster["resources"]:
        if resource["kind"] == "Deployment" and resource["name"] == OPTIMISER_DEPLOYMENT:
            return resource
    raise RuntimeError(f"No optimiser Deployment found in {cluster['context']}")


def desired_replicas(resource):
    replicas = resource["spec"].get("replicas")
    return 1 if replicas is None else replicas


def validate_optimiser_configuration(clusters):
    if not any(desired_replicas(optimiser_workload(cluster)) > 0 for cluster in clusters):
        raise RuntimeError(
            "Both optimisers have zero replicas. Enable an optimiser before running "
            "the restore so Flyway can initialise optimiserdb before consumers restart."
        )


def stop_cluster(cluster, timeout):
    context = cluster["context"]
    resources = cluster["resources"]

    # Suspend reconcilers and job producers before draining existing jobs.
    for resource in resources:
        if resource["kind"] not in WORKLOAD_KINDS:
            patch(context, resource, stopped(resource))

    wait_for_controllers(context, resources, timeout)
    wait_until(lambda: jobs_finished(context), f"jobs to drain in {context}", timeout)

    for resource in resources:
        if resource["kind"] in WORKLOAD_KINDS:
            patch(context, resource, stopped(resource))


def stop(path, contexts, run_id, timeout):
    if path.exists():
        raise RuntimeError("Workload state already exists; recover it before another restore")
    state = {
        "run_id": run_id,
        "clusters": [{"context": context, "shutdown_started": False} for context in contexts],
    }
    # Lock both clusters before reading settings: another run may currently have
    # replicas at zero, and those must never become this run's recovery settings.
    save(path, state)
    acquire_restore_locks(path, state)

    for cluster in state["clusters"]:
        cluster.update(snapshot(cluster["context"]))
    validate_optimiser_configuration(state["clusters"])

    # Persist every snapshot locally and in Kubernetes before touching workloads.
    save(path, state)
    for cluster in state["clusters"]:
        persist_cluster_snapshot(cluster)

    for cluster in state["clusters"]:
        cluster["shutdown_started"] = True
        save(path, state)
        persist_cluster_snapshot(cluster)
        stop_cluster(cluster, timeout)
    for cluster in state["clusters"]:
        wait_until(
            lambda: not active_pods(cluster["context"]),
            f"all pods to stop in {cluster['context']}",
            timeout,
        )


# -----------------------------------------------------------------------------
# Workload recovery
# -----------------------------------------------------------------------------
def holds_restore_lock(cluster, run_id):
    context = cluster["context"]
    lock_contents = kubectl(
        context, NAMESPACE,
        "get", f"configmap/{LOCK}", "--ignore-not-found", "-o", "json",
    )
    if lock_contents and json.loads(lock_contents)["data"]["run-id"] == run_id:
        return True
    if not cluster.get("locked"):
        # A cluster where lock acquisition failed was never modified by us.
        return False
    raise RuntimeError(f"Restore lock is missing or changed in {context}")


def check_resource_identities(cluster):
    for resource in cluster["resources"]:
        current = get(
            cluster["context"],
            resource["namespace"],
            f"{resource['kind']}/{resource['name']}",
        )
        if current["metadata"]["uid"] != resource["uid"]:
            raise RuntimeError(f"Resource replaced during restore: {resource['name']}")


def restore_optimisers(clusters, modified_clusters, timeout):
    validate_optimiser_configuration(clusters)
    modified_contexts = {cluster["context"] for cluster in modified_clusters}

    # The database is shared. Wait for every originally enabled optimiser across
    # both clusters before allowing any consumers or job producers to restart.
    for cluster in clusters:
        resource = optimiser_workload(cluster)
        if desired_replicas(resource) == 0:
            continue
        context = cluster["context"]
        if context in modified_contexts:
            patch(context, resource, original(resource))
        kubectl(
            context, NAMESPACE,
            "rollout", "status", f"Deployment/{OPTIMISER_DEPLOYMENT}",
            f"--timeout={timeout}s",
        )


def restore_workloads(cluster, timeout):
    context = cluster["context"]
    workloads = [
        resource for resource in cluster["resources"]
        if resource["kind"] in WORKLOAD_KINDS and resource["name"] != OPTIMISER_DEPLOYMENT
    ]

    for resource in workloads:
        patch(context, resource, original(resource))
        if resource["spec"].get("replicas", 1) != 0:
            kubectl(
                context, NAMESPACE,
                "rollout", "status", f"{resource['kind']}/{resource['name']}",
                f"--timeout={timeout}s",
            )


def restore_controllers(cluster):
    for resource in reversed(cluster["resources"]):
        if resource["kind"] not in WORKLOAD_KINDS:
            patch(cluster["context"], resource, original(resource))


def resume_cluster(cluster, run_id, timeout):
    if not holds_restore_lock(cluster, run_id):
        return False

    # A failed lock acquisition or snapshot never changed workload settings.
    # Release only this run's lock in that case, without applying any snapshot.
    if cluster.get("shutdown_started"):
        restore_workloads(cluster, timeout)
        restore_controllers(cluster)
    kubectl(cluster["context"], NAMESPACE, "delete", "configmap", LOCK)
    return True


def resume(path, timeout):
    if not path.exists():
        return
    state = json.loads(path.read_text())
    owned_clusters = []
    for cluster in state["clusters"]:
        if not cluster.get("resumed") and holds_restore_lock(cluster, state["run_id"]):
            owned_clusters.append(cluster)

    modified_clusters = [cluster for cluster in owned_clusters if cluster.get("shutdown_started")]
    for cluster in modified_clusters:
        check_resource_identities(cluster)
    if modified_clusters:
        restore_optimisers(state["clusters"], modified_clusters, timeout)

    failures = []
    for cluster in owned_clusters:
        context = cluster["context"]
        try:
            if resume_cluster(cluster, state["run_id"], timeout):
                cluster["resumed"] = True
                save(path, state)
        except (RuntimeError, subprocess.CalledProcessError, KeyError) as error:
            failures.append(f"{context}: {error}")
    if failures:
        raise RuntimeError("Could not resume all clusters: " + "; ".join(failures))


# -----------------------------------------------------------------------------
# Main execution flow
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stop", "resume"))
    parser.add_argument("state", type=Path)
    parser.add_argument("--contexts", nargs="+")
    parser.add_argument("--run-id")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        if args.action == "stop":
            if not args.contexts or not args.run_id:
                parser.error("stop requires --contexts and --run-id")
            stop(args.state, args.contexts, args.run_id, args.timeout)
        else:
            resume(args.state, args.timeout)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
