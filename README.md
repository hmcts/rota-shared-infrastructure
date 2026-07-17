# rota-shared-infrastructure

Shared per-environment resources for the rota services:

- PostgreSQL 16 database used as the optimiser control plane and worker-lease authority;
- Application Insights;
- the `rota-shared-<environment>` Key Vault;
- PostgreSQL connection secrets;
- a generated `optimiser-hmac-key` shared by the optimiser and worker deployments.

The HMAC key is generated once per Terraform state and stored only as a sensitive Terraform value
and Key Vault secret. Application charts mount the secret but enable HMAC and mandatory lease-token
enforcement in later rollout steps, after both clusters are running compatible worker images.
