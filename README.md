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

## PostgreSQL diagnostic logging

In the production-level environments (AAT, performance test and production), both PostgreSQL servers
send the same six diagnostic log categories and `AllMetrics` used by the legacy CPP deployment to the
standard central CNP Log Analytics workspace in the `oms-automation` resource group. The local CNP
workspace mapping sends AAT and performance test diagnostics to `hmcts-nonprod`, and production
diagnostics to `hmcts-prod`. Creation is controlled by the same `pgsql_enable_query_diagnostics`
setting used for PostgreSQL query diagnostics; it is enabled in the AAT, performance test and
production tfvars and defaults to disabled in other environments.

The diagnostic settings use the legacy `AzureDiagnostics` destination so existing queries remain
compatible. The same `pgsql_enable_query_diagnostics` setting also enables Query Store and enhanced
database metrics on the PostgreSQL servers.

### Differences from the legacy CPP-managed PaaS deployment

The HMCTS PostgreSQL module used for AKS-hosted applications does not expose every integration option
used by the legacy CPP PostgreSQL module, so the following have not been added outside the module:

- the Monday 02:00 UTC maintenance window (the AKS module currently fixes this to Sunday 03:00 UTC);
- the legacy CPP Entra role/group model and its external credential-vault integration.
