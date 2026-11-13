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
