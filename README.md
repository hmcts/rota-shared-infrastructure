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

## Distributing anonymised database dumps

Register `azure-pipelines-distribute-anonymised-dump.yml` as a pipeline in the PlatformOperations
Azure DevOps project. Run it manually from the desired branch and enter the existing PRD
`anonymised-db-dumps` blob filename in `blobName`, with or without the `.backup.enc` suffix.
The script appends `.backup.enc` if needed: entering `rota-20261029` selects the existing blob
`rota-20261029.backup.enc`. The filename is required and must start with a letter or digit;
it may contain letters, digits, dots, underscores and hyphens.

The pipeline runs `scripts/distribute-anonymised-dump.sh` to copy that one blob from
`rotasaprod/anonymised-db-dumps` to `rotasaaat/anonymised-db-dumps`. AAT is the only destination
configured in this pipeline. The source blob stays in PRD.

Before copying, the script checks that the named blob is absent from AAT. An existing blob or a
failed destination check stops the run before copying. AzCopy handles a missing source or a
transfer failure; its nonzero exit status stops the script. After copying, the script checks that
the destination blob exists. Existing blobs are never overwritten.

AzCopy transfers the blob directly between storage accounts, so the dump is not downloaded to
the agent. The job has a 150-minute timeout.

The pipeline uses the `hmcts-cftptl-agent-pool` Linux agent pool and the existing
`DTS-CFTPTL-INTSVC` Azure service connection. Apply the Terraform for production and
AAT first: it permits the CFT PTL AKS agent subnets through each storage firewall and grants
that connection's service principal read access to the production container and write access
to the AAT container. AzCopy reuses the Azure CLI login via `AZCOPY_AUTO_LOGIN_TYPE=AZCLI`;
the blob existence checks use `--auth-mode login`.

### Differences from the legacy CPP-managed PaaS deployment

The HMCTS PostgreSQL module used for AKS-hosted applications does not expose every integration option
used by the legacy CPP PostgreSQL module, so the following have not been added outside the module:

- the Monday 02:00 UTC maintenance window (the AKS module currently fixes this to Sunday 03:00 UTC);
- production diagnostic settings targeting the shared `LA-MPD-INT-WS` workspace, including all
  metrics (the module's Query Performance Insight option creates a separate workspace and overrides
  query-capture settings, so it is not equivalent);
- the legacy CPP Entra role/group model and its external credential-vault integration.
