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

Register `azure-pipelines-anonymise-database.yml` as a manually run pipeline in the
PlatformOperations Azure DevOps project. It uses `hmcts-cftptl-agent-pool` and the existing
`DTS-CFTPTL-INTSVC` service connection. Supply the production subscription explicitly; the script
switches from the service connection's default subscription before accessing production resources.

This reproduces `automation.ansible/sp-ansible/rota_flexible_anondb.yml` for the new infrastructure:

1. Read the DAPDB hostname and admin credentials from `rota-shared-prod` Key Vault.
2. Restore `rota-psql-dapdb-prod` at the supplied UTC timestamp into
   `rota-dapdb-anon-<Build.BuildId>-<System.JobAttempt>` in `rota-shared-infra-prod`.
3. Run the existing `rota_anonymisation` package against the temporary server, streaming its stdout
   and stderr directly into an encrypted diagnostic log. Encrypt its checks CSV and delete the
   plaintext CSV before creating the backup.
4. Stream only `mojdb`'s `public` schema in PostgreSQL custom format directly into OpenSSL, using
   AES-256-CTR, PBKDF2 with 600,000 iterations, SHA-512 and a random salt. No plaintext backup file is
   written to the agent. Decrypt through a pipe to check the archive contents with `pg_restore --list`.
5. When `publishDump` is enabled, upload only the completed `.backup.enc` file to
   `rotasaprod/anonymised-db-dumps` without overwriting,
   then check the remote blob size against the local file size.
6. Delete the temporary server and local package/dump files. The pipeline retries cleanup in an
   `always()` step using a fresh Azure login. After a successful workflow, encrypted checks and
   diagnostics are published as a pipeline artifact; failed workflows discard them. Final cleanup
   removes the local encrypted files.

The original server is only read for restore metadata; anonymisation and `pg_dump` target the
temporary server. Only the encrypted dump is held on the Azure DevOps agent during creation/upload.
Its blob filename includes UTC time, build ID and job attempt, for example
`mojdb_anonymised_2026-10-29_12-30-00_12345-1.backup.enc`.

### Pipeline inputs and assumptions

| Input | Required value |
| --- | --- |
| `productionSubscriptionId` | Subscription UUID containing the new production resources. |
| `pitrTimestamp` | Available restore point in UTC, formatted `YYYY-MM-DDTHH:mm:ssZ`. |
| `anonymisationVersion` | Exact released `rotadb-migration` version compatible with the source schema. `latest` and snapshots are not supported. |
| `repositoryUrl` | Reachable HTTPS Maven repository root, ending in `/repocentral`. |
| `postgresqlHome` | Agent directory containing PostgreSQL 15 `bin/psql`, `bin/pg_dump` and `bin/pg_restore`. |
| `anonymisationUser` | Defaults to `pgadmin`, the new DAPDB admin. Override if the package requires a different user such as `moj_user`. |
| `anonymisationPasswordSecret` | Defaults to `dapdb-postgresql-admin-password`. Override with the Key Vault secret holding the chosen user's password. |
| `encryptionPasswordSecret` | Defaults to `anonymised-db-dump-encryption-password` in `rota-shared-prod`. This is a separate backup encryption password. |
| `publishDump` | Defaults to `false`. Enable only after validating the package and its checks report. |

The package coordinates match Ansible:
`com.moj.magsrota.portal.build:rotadb-migration:<version>:anonymisation:tar.gz`.
It must extract an executable `rota_anonymisation` at its root. The pipeline calls it with the
temporary server's hostname and supplies `POSTGRESQL_HOME`, `PGHOST`, `PGUSER`, `PGDATABASE=mojdb`,
`PGPASSWORD` and `PGSSLMODE=require`. It also adds the PostgreSQL client `bin` and `lib` directories
to `PATH` and `LD_LIBRARY_PATH`. If Artifactory needs authentication, define the secret pipeline
variable `rotaAnonymisationArtifactoryToken`; otherwise leave it undefined.

The package itself has not yet been inspected. Its user handling and additional dependencies remain
assumptions to verify. The pipeline requires a zero exit status and a nonempty
`/tmp/rota_anonymised_database_checks.csv`, but does **not** interpret the CSV or establish that
personal data has been removed. A host-level lock prevents concurrent runs from sharing that fixed
report path. A validation run (`publishDump=false`) still restores, anonymises, encrypts and validates
the dump, then deletes it without uploading. Decrypt and review the retained checks artifact in a
protected environment before publishing.

### Encryption, restore compatibility and failure cleanup

`pg_dump` writes to a pipe feeding this command, with `ENCPASSWORD` supplied only to the OpenSSL
process from the configured Key Vault secret:

```bash
openssl enc -aes-256-ctr -pbkdf2 -iter 600000 -md sha512 -salt \
  -out "$FILENAME.backup.enc" -pass env:ENCPASSWORD
```

The script uses `pipefail` so a failed `pg_dump` cannot be hidden by successful encryption of an
incomplete stream. Both encryption and decrypted archive-list validation must succeed before upload.
The entire decrypted stream is drained without writing a plaintext file. This checks archive
readability, rather than performing a full restore or proving anonymisation. AES-CTR encryption does
not authenticate the backup; the archive check is not a cryptographic tamper-detection mechanism.

The same encryption settings and Key Vault password protect the retained diagnostics and checks:

- `anonymisation_<run-id>.log.enc` contains the anonymiser's combined stdout and stderr. Its raw output
  never passes through the pipeline logger or a plaintext log file.
- `rota_anonymised_database_checks_<run-id>.csv.enc` contains the checks report. Encryption must
  succeed, and the original CSV must be deleted, before the backup is created or uploaded.

The existing `anonymisation-checks-<run-id>` pipeline artifact contains only these encrypted files.
It is published only after success, and final cleanup removes the local copies. On failure both
encrypted outputs are discarded along with the other temporary files. Anonymisation or diagnostic
encryption failure stops the workflow; successful log encryption cannot hide an anonymiser failure.

Pipeline output contains workflow status and generic failures instead of raw anonymiser output.
The script disables inherited shell tracing before handling credentials or data.
Database-client stderr from connection checks, dumping and archive validation is suppressed because
it can include database details. Those failures produce generic messages, without retaining that
client stderr. Diagnostic encryption errors are also suppressed and replaced with a generic failure.

The package still writes its original CSV to `/tmp/rota_anonymised_database_checks.csv` while running.
Encrypting and deleting that file afterwards cannot prevent exposure from an interrupted agent
before encryption. The package's additional file writes remain unverified. Inspect the package and
verify protected temporary storage before relying on this workflow for production data handling.

Restores need the same encryption password and PBKDF2 settings. Preserve the Key Vault secret
version/password used for every retained backup. Verify OpenSSL version and salt-length compatibility
between the encrypting and restoring agents. For example, to inspect the decrypted archive:

```bash
set -o pipefail
openssl enc -d -aes-256-ctr -pbkdf2 -iter 600000 -md sha512 -salt \
  -in "$FILENAME.backup.enc" -pass env:ENCPASSWORD |
  (pg_restore --list && cat >/dev/null)
```

For a checks report or diagnostic log, use the same OpenSSL decryption options with the appropriate
`.csv.enc` or `.log.enc` input and omit `pg_restore`. Treat decrypted diagnostics as production data;
inspect them in a protected environment and never print them into pipeline logs.

The legacy encrypted-backup restore command omits `-pbkdf2 -iter 600000`; it must be updated before
reading backups produced here. The new infrastructure's restore pipeline will also need decryption
support before these dumps can be restored.

On a detected workflow failure, cleanup removes this run's package files, partial encrypted dump,
encrypted reports/diagnostics and plaintext checks report, and attempts to delete the temporary
database server. Local data is removed before waiting for Azure deletion. The separate cleanup task
also recovers a fixed-path CSV
left by an interrupted run, using the lock's run ID to avoid deleting another run's report. Only
successfully completed workflows publish encrypted checks and diagnostics; the final task deletes
the local copies even if report publication fails.

This workflow never uploads a plaintext backup or report to the dump container, so it creates no
plaintext blobs requiring deletion. Existing blobs from other runs are outside its cleanup scope.
A failed upload or a later failure can leave an encrypted blob, which should be checked before use.
Agent loss, forced termination or denied deletion can still require manual cleanup; cleanup errors
fail the job and identify the affected paths and server. The external anonymisation package must be
reviewed for any additional files it creates outside these known locations.

### Setup and first-run checklist

- Register/authorize the pipeline and the `DTS-CFTPTL-INTSVC` service connection.
- Supply a compatible package version and repository URL. Inspect `rota_anonymisation` to confirm
  its database username, dependencies, failure behaviour and CSV interpretation. If needed, seed a
  password secret in `rota-shared-prod` for the required database user and select it in the pipeline.
- Apply the production Terraform to create `anonymised-db-dump-encryption-password` in
  `rota-shared-prod`, and grant the connection read access. `keyvault-secrets.tf` generates a stable
  64-character password only for `prod`; the password and secret resources use `prevent_destroy`
  to guard against accidental replacement or deletion. An existing dedicated secret can instead be
  selected through `encryptionPasswordSecret`. Retain the password/secret versions for restores
  after any deliberate rotation. The generated password is also stored in Terraform state, so
  restrict access to that state as for the existing database credentials.
- Provision PostgreSQL 15 clients, OpenSSL supporting the requested PBKDF2 options, Azure CLI,
  `curl`, `tar` and `flock` on the Linux agent. Ensure it has enough temporary disk space for the
  package and full encrypted dump, and verify the OpenSSL version used by the restore agent.
- Apply the production Terraform after reviewing its plan. `storage.tf` grants the connection's
  principal `Storage Blob Data Contributor` on the dump container so it can upload and read dumps;
  the role is also used for distribution in other environments. It grants no server-management or
  Key Vault permissions.
- Separately grant that principal access to the required Key Vault secrets and permission to read
  the source server and create/delete temporary PostgreSQL servers in `rota-shared-infra-prod`.
  Include the delegated subnet/private DNS permissions needed for restoring the private server.
- Verify agent DNS/routing to the restored PostgreSQL server, Key Vault, Artifactory and Blob Storage.
  Restores use the source server's network configuration. Confirm subnet capacity and restore quota.
- Select a restore timestamp within retention. Credentials must match that restore point; a password
  rotation since that timestamp can make the current Key Vault password unsuitable for the clone.
- Run with `publishDump=false`, decrypt and review the checks CSV in a protected environment, and
  verify the package's anonymisation results.
  Once validated, rerun with `publishDump=true` and check the reported blob filename.
- Check that the temporary server was removed. Cleanup failures fail the job and identify its name.
  Agent loss, forced termination or an in-progress Azure restore can require manual cleanup; use
  `az postgres flexible-server delete --resource-group rota-shared-infra-prod --name <temporary-server> --yes`.
- Before distributing the new production dump, update `source_account` in
  `scripts/distribute-anonymised-dump.sh` from `rotasademo` to `rotasaprod`; the existing distribution
  pipeline still copies Demo to AAT.

Azure CLI references: [PostgreSQL restore](https://learn.microsoft.com/en-us/cli/azure/postgres/flexible-server#az-postgres-flexible-server-restore)
and [blob upload](https://learn.microsoft.com/en-us/cli/azure/storage/blob#az-storage-blob-upload).
Encryption reference: [OpenSSL enc](https://docs.openssl.org/3.6/man1/openssl-enc/).

Local verification: run `bash -n scripts/anonymise-database.sh` and
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`. The tests use fake Azure and
PostgreSQL commands and a fixture package; they do not contact Azure or validate the real anonymiser.
They cover streaming failures and cleanup, and include an encryption/decryption round trip using
real OpenSSL when it is installed. Sensitive fixture values in stdout, stderr and CSV content are
checked against pipeline output and retained files; only decrypted encrypted artifacts contain them.

## Distributing anonymised database dumps

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

### Differences from the legacy CPP-managed PaaS deployment

The HMCTS PostgreSQL module used for AKS-hosted applications does not expose every integration option
used by the legacy CPP PostgreSQL module, so the following have not been added outside the module:

- the Monday 02:00 UTC maintenance window (the AKS module currently fixes this to Sunday 03:00 UTC);
- production diagnostic settings targeting the shared `LA-MPD-INT-WS` workspace, including all
  metrics (the module's Query Performance Insight option creates a separate workspace and overrides
  query-capture settings, so it is not equivalent);
- the legacy CPP Entra role/group model and its external credential-vault integration.
