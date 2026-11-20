# rota-shared-infrastructure

Shared per-environment resources for the rota services:

- DAPDB and DOPDB PostgreSQL 15 Flexible Servers used by the Rota services;
- Application Insights;
- the `rota-shared-<environment>` Key Vault;
- PostgreSQL connection secrets;
- an operationally seeded `optimiser-hmac-key` shared by the optimiser and worker deployments.

The HMAC key is not managed by Terraform. Seed the `optimiser-hmac-key` secret directly in each
environment's existing Key Vault before enabling the chart secret mount or HMAC enforcement.
Application charts enable HMAC and mandatory lease-token enforcement only in later rollout steps,
after both clusters are running compatible worker images.

## PostgreSQL sizing

The databases are not hosted inside AKS. They remain Azure Database for PostgreSQL Flexible Server
PaaS resources, with applications in AKS connecting to them over the delegated subnet. Consequently,
server sizing, storage, backup, high-availability, auto-grow and PostgreSQL tuning settings remain
applicable; running the client workloads in AKS does not replace those server-side concerns.

The DAPDB and DOPDB servers default to the development specification. Environment-specific sizing
is applied by setting the PostgreSQL variables in an environment's `<env>.tfvars` file, following the
standard HMCTS pipeline convention. `prod.tfvars`, `perftest.tfvars` and `aat.tfvars` (staging) supply the
full production sizing, high availability, retention and diagnostics values. Environments without an
override file (`dev`, `sandbox`, `ithc`, `demo`) use the development defaults declared in `variables.tf`.

The existing generic `postgresql-*` Key Vault secrets and `postgresql_fqdn` output now refer to
DAPDB for compatibility. Explicit `dapdb-postgresql-*` and `dopdb-postgresql-*` secrets are also
created.

## Producing an anonymised production database dump

Register `azure-pipelines-anonymise-database.yml` as a manual pipeline in PlatformOperations.
It uses `hmcts-cftptl-agent-pool`, the `DTS-CFTPTL-INTSVC` service connection and the fixed
`DCD-CNP-Prod` subscription (`8999dec3-0104-4a27-94ee-6588559729d1`).

The workflow follows the legacy Ansible process:

1. Restore `rota-psql-dapdb-prod` to a temporary server in `rota-shared-infra-prod`.
2. Run the versioned `rota_anonymisation` package against that temporary server.
3. Require successful anonymisation and zero failures in its checks CSV, then delete the CSV.
4. Stream a custom-format dump of `mojdb.public` directly through OpenSSL encryption.
5. Upload the `.backup.enc` file to `rotasaprod/anonymised-db-dumps`.
6. Remove local working files and delete the temporary server, on success or failure.

| Pipeline input | Value |
| --- | --- |
| `pitrTimestamp` | Available restore point in UTC (`YYYY-MM-DDTHH:mm:ssZ`). |
| `anonymisationVersion` | Exact released package version matching the database schema; snapshots are unsupported. |

Set these one-time variables in the pipeline YAML before running:

| Configuration | Value |
| --- | --- |
| `artifactoryRepository` | Replace `REPLACE_WITH_MAVEN_REPOSITORY` with the Maven repository containing the released anonymisation package. |
| `postgresqlHome` | Set to `/usr`, using the agent's packaged `/usr/bin/psql` and `/usr/bin/pg_dump` commands. |
| `anonymisationPasswordSecret` | Set to `portal-owner-password` in `rota-shared-prod`, holding the restored database's `portal_owner` password. |

The Artifactory repository remains a placeholder. The PostgreSQL path and password-secret name are
configured. Every successful run uploads the encrypted dump; there is no separate upload switch.

The [agent Dockerfile](https://github.com/hmcts/azure-devops-agent/blob/main/Dockerfile) installs
Ubuntu's `postgresql-client` package; its client version follows the agent image.

The Artifactory host is fixed to `https://artifactory.platform.hmcts.net/artifactory`.
The package has not been published yet. Set `artifactoryRepository` in the pipeline YAML when its
Maven repository is known. The coordinates match Ansible:
`com.moj.magsrota.portal.build:rotadb-migration:<version>:anonymisation:tar.gz`.
If authentication is required, set the secret pipeline variable `rotaAnonymisationArtifactoryToken`.

The package must contain executable `rota_anonymisation` at its root and produce
`/tmp/rota_anonymised_database_checks.csv`. Before publishing, replace the legacy script's hardcoded
`-U moj_user` with `-U "$PGUSER"`, remove the SQL's `OWNER TO moj_user`, and enable `ON_ERROR_STOP=1`
on every `psql` invocation. The wrapper supplies `PGUSER=portal_owner` and its Key Vault password;
the package must handle SQL failures itself, without a temporary `PSQLRC` workaround.
The CSV must have the legacy `Table Name,Column Name,Anonymisation Failures` header and at least one
check, with every failure count zero. These checks depend on the package's coverage of personal data.

### Encryption and cleanup

The password comes from `anonymised-db-dump-encryption-password` in `rota-shared-prod`, created by
Terraform for production. The dump streams into:

```bash
openssl enc -aes-256-ctr -pbkdf2 -iter 600000 -md sha512 -salt \
  -out "$FILENAME.backup.enc" -pass env:ENCPASSWORD
```

No plaintext backup file is created. Raw anonymiser output is discarded to keep its production data
out of pipeline logs; checks and diagnostic artifacts are not retained. The package's plaintext CSV
is deleted after validation, with a small lock protecting its fixed path during execution and cleanup.
Dump or encryption failure prevents upload. The upload refuses to overwrite existing blobs.

Exit/signal traps perform cleanup, and a final `always()` task retries with a fresh Azure login.
The job allows two hours, with 30 minutes for cancellation cleanup, within the agent's three-hour
lifetime. Longer runs require extending the agent lifetime before increasing the pipeline timeout.
Cleanup errors fail the job and identify the temporary server and local paths. Agent loss or an
Azure deletion failure can still leave a temporary server requiring manual deletion. The legacy
package writes its CSV before validation; forced agent loss can prevent its removal. Only encrypted
files are uploaded, and a failed run may leave an encrypted blob.

Restore tooling must use the same password and OpenSSL options, adding `-d` to decrypt. Preserve the
password versions needed for retained backups and verify OpenSSL compatibility with the restore
agent. AES-CTR does not authenticate the backup, and this pipeline does not perform a test restore.

### Before the first run

- Update and publish the package as described above, then replace the `artifactoryRepository`
  placeholder in the pipeline YAML. The agent client path and password-secret name are already set.
- Ensure the database-users configuration providing `portal_owner` and `portal-owner-password` has
  been applied in production, and the restored database uses that ownership model.
- Review and apply production Terraform for the encryption secret and container access. The generated
  password is held in Terraform state; retain it for restores and protect access to that state.
- Authorise the service connection to read the Key Vault secrets, restore/delete temporary servers,
  and upload blobs. Include the delegated subnet/private DNS permissions needed by the restore.
- Ensure the agent has PostgreSQL clients, OpenSSL, Azure CLI, `awk`, `curl`, `tar` and `flock`,
  sufficient temporary disk space, and network access to the private database and Azure services.
- Confirm package compatibility before running; a successful run uploads the encrypted backup.
  Passwords must match the selected restore point.
- Before distributing production dumps, change `source_account` in
  `scripts/distribute-anonymised-dump.sh` from `rotasademo` to `rotasaprod`.

## Distributing anonymised database dumps

The distribution pipeline is temporarily configured to test Demo blob permissions. Run
`azure-pipelines-distribute-anonymised-dump.yml` manually without parameters. It runs
`scripts/test-blob-permissions.sh`, which creates a small, uniquely named file on the agent,
uploads it to `rotasademo/anonymised-db-dumps`, downloads it and compares the contents. The
test blob stays in storage for inspection; its URL is printed in the pipeline logs.

The test uses the same `hmcts-cftptl-agent-pool` agent pool and `DTS-CFTPTL-INTSVC` Azure
service connection as distribution. Both transfers use Azure CLI with `--auth-mode login`
to test that connection's Microsoft Entra identity. Distribution's AzCopy transfers use
the same Azure CLI login via `AZCOPY_AUTO_LOGIN_TYPE=AZCLI`.

### Original distribution workflow

The instructions below apply after restoring the pipeline to run
`scripts/distribute-anonymised-dump.sh` with the original parameters.

Register `azure-pipelines-distribute-anonymised-dump.yml` as a pipeline in the PlatformOperations
Azure DevOps project. Run it manually with the Demo `anonymised-db-dumps` blob filename in
`blobName`. The source is `rotasademo` for testing until production exists, and the only destination
is `rotasaat`. The source blob stays in place. Filenames must start with a letter or digit and may
contain letters, digits, dots, underscores and hyphens.

Before copying, the script checks that the named blob is absent from AAT. An existing blob or a
failed destination check stops the run. AzCopy handles a missing source or a transfer failure; its
nonzero exit status stops the script. After copying, the script checks that the destination blob
exists. Existing blobs are never overwritten.

The pipeline uses the `hmcts-cftptl-agent-pool` Linux agent pool and the existing
`DTS-CFTPTL-INTSVC` Azure service connection. Apply the Terraform for Demo and AAT to permit the
CFT PTL AKS agent subnets through their storage firewalls. The connection's service principal also
needs read access to the Demo container and write access to the AAT container; `storage.tf` now
provides container-scoped contributor access when each environment's Terraform is applied.

## Restoring a non-production environment

Register `azure-pipelines-restore-anonymised-database.yml` as a manual pipeline in
PlatformOperations. It uses `DTS-CFTPTL-INTSVC` and `hmcts-cftptl-agent-pool`.

| Pipeline input | Value |
| --- | --- |
| `environment` | Target environment: `dev`, `sandbox`, `aat`, `demo`, `ithc` or `perftest`. |
| `blobName` | Exact decrypted PostgreSQL backup filename in `rotasa<environment>/anonymised-db-dumps`. |
| `targetSubscription` | Subscription ID containing the target PostgreSQL servers, Key Vault and blob store. |
| `aksSubscription` | Subscription ID containing both target AKS clusters. |

The source blob store follows the target environment and uses `targetSubscription`. For example,
a `perftest` restore reads from `rotasaperftest/anonymised-db-dumps` in the supplied perftest
subscription. The selected dump must already be present in that environment's container.
Download the encrypted dump from AAT after anonymisation, decrypt it locally, then upload the
decrypted PostgreSQL custom-format archive manually to each required non-production environment's
blob store. For example, upload `mojdb_anonymised.backup` after decrypting its `.backup.enc` file.
The restore pipeline reads that archive directly. It requires no encryption password, OpenSSL,
production subscription or production Key Vault access. The filename must be a single name using
letters, digits, dots, underscores or hyphens; `pg_restore` validates its actual archive contents.
An encrypted file is rejected during preflight, regardless of its filename. Production targets
are excluded by the environment allowlist.

The pipeline follows the database reset/restore sequence from Ansible, adapted to the new structure:

1. Download the decrypted dump, read the complete archive, and check target database access.
2. Discover both `cft-<environment>-00-aks` and `cft-<environment>-01-aks` in the supplied AKS
   subscription. Acquire locks in both clusters before reading the original workload/controller
   settings. Save both snapshots locally and in the locks before changing any workloads.
3. Suspend the Rota Flux Kustomization and HelmReleases,
   pause KEDA and CronJobs, drain active Jobs, and scale Deployments and StatefulSets to zero.
   Require all non-completed pods in both clusters to stop before changing either database.
4. Replace `mojdb.public` on `rota-psql-dapdb-<environment>` using the selected dump. Restore objects
   as `portal_owner`, without importing production ownership or ACLs.
5. Rebuild an empty `optimiserdb.public` on `rota-psql-dopdb-<environment>`. The new optimiser owns
   its schema migrations; the legacy `optimisationdb` and `persistdb` databases are not recreated.
6. Restore every originally enabled optimiser across both clusters and wait for readiness/Flyway
   before restarting any consumers. Then restore the remaining replica counts and controller
   settings. Workloads that were stopped remain stopped. At least one optimiser must have a
   positive replica count before starting a restore; if both are zero, preflight releases its
   locks and fails before changing workloads or either database.

The databases themselves are retained, preserving their locale, database-level grants and settings.
Each schema rebuild runs in a transaction. Target schema ownership, schema grants, schema-scoped
default grants and the configured PostgreSQL extensions are restored, with owner/application grants
matching the new database-users setup. The portal and optimiser schema transactions are separate.
The existing HA configuration is retained. The downloaded plaintext archive is stored in the run's
private agent directory and removed by cleanup, including when database restoration fails. It is
never included in the recovery artifact. Archive listing and import read the downloaded file by
filename, avoiding early-reader pipe failures on large dumps.

### Restore prerequisites

- Apply the database-user setup from `dev/PET-8240-database-users` to the target first. This restore
  branch does not provision users or reset their passwords. It requires `portal_owner`, `portal_user`,
  `optimiser_owner` and `optimiser_user`, with each database administrator able to assume its owner role.
- Allow the service connection to read the target's `dapdb-postgresql-*` and `dopdb-postgresql-*`
  Key Vault secrets and blobs in the target environment's container.
- Give that identity AKS credential access and Kubernetes permissions in both clusters to read
  workloads, patch Deployments/StatefulSets/HelmReleases/CronJobs/KEDA resources, manage the restore
  ConfigMap (create, patch and delete), and suspend the `rota` Kustomization in `flux-system`. Server-side dry runs check the
  patch permissions before shutdown.
- Provide network access from the agent to the target environment's storage, both private PostgreSQL
  servers, both Kubernetes APIs and Key Vault. The agent needs Azure CLI, `kubectl`, `kubelogin`, Python 3
  and PostgreSQL 15 `pg_restore` plus `psql`. The YAML sets `postgresqlHome` to
  `/usr/lib/postgresql/15`; install that client version in the agent image or update the path.
  Produce dumps with PostgreSQL 15 `pg_dump` as well; archives from newer clients can be incompatible.
- Both cluster names above must exist. Unexpected DaemonSets or HPAs with `minReplicas: 0` cause
  preflight failure and need a reviewed maintenance policy. Active Jobs have ten minutes to drain.
- Avoid deployments and manual workload changes during restoration. Confirm the restore fits the
  two-hour job timeout and the disposable agent's three-hour lifetime before using a large dump.

### Failure and recovery

A shutdown failure before database work restores the original workload settings. A failed database
transaction rolls back that schema, but a later failure may follow an already committed schema in
the other database. In that case the pipeline deliberately leaves both clusters stopped.
If an enabled optimiser fails its readiness check during recovery, consumers and job producers
remain stopped and the locks remain in place so recovery can be retried. No consumer in either
cluster is restarted until all originally enabled optimisers are ready.

Exit traps and a final `always()` task retry workload recovery after successful database work.
The pipeline publishes `database-restore-<build>-<attempt>` containing the original settings and
database progress markers, without credentials or database contents. Recovery errors fail the job.

For an incomplete restore, repair/re-run the database work while the environment remains stopped.
Once both databases are consistent, authenticate to the two clusters, set `KUBECONFIG`, and run:

```bash
python3 scripts/restore-workloads.py resume /path/to/workloads.json
```

The command checks resource UIDs and the run's lock before restoring settings; it can be retried.
If an agent is lost before publishing the artifact, each cluster's `rota/rota-database-restore`
ConfigMap contains `run-id` and, once snapshots are complete, `workload-state`. Reconstruct the recovery
JSON with that `run_id` and a `clusters` array containing the two saved `workload-state` objects,
including their `shutdown_started` flags. A lock without a snapshot was acquired before workload
changes; represent it with its `context`, `locked: true` and `shutdown_started: false`. Recovery
releases owned locks for untouched clusters without applying settings. Do not delete another run's
locks or resume after an incomplete database restore until database consistency has been verified.

Run the offline recovery checks with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
```

Optional PostgreSQL 15 integration tests use `RESTORE_TEST_SOCKET`, `RESTORE_TEST_PORT` and
`RESTORE_TEST_CLIENT_BIN`. Use a disposable local server. The suite refuses to start if any fixture
database or role name already exists, tracks successful fixture creation and removes only those
created fixtures. Its uncompressed synthetic archive is larger than 16 MiB to exercise preflight
and import beyond pipe-buffer sizes.

### Differences from the legacy CPP-managed PaaS deployment

The HMCTS PostgreSQL module used for AKS-hosted applications does not expose every integration option
used by the legacy CPP PostgreSQL module, so the following have not been added outside the module:

- the Monday 02:00 UTC maintenance window (the AKS module currently fixes this to Sunday 03:00 UTC);
- production diagnostic settings targeting the shared `LA-MPD-INT-WS` workspace, including all
  metrics (the module's Query Performance Insight option creates a separate workspace and overrides
  query-capture settings, so it is not equivalent);
- the legacy CPP Entra role/group model and its external credential-vault integration.
