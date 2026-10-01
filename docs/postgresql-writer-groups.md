# Rota PostgreSQL writer groups

The shared PostgreSQL module has no writer-group-name input. In production it
uses the Entra group `DTS JIT Access rota DB Writer SC`. In non-production it
uses the PostgreSQL role name `DTS CFT DB Access Writer`. Do **not** create a
CFT-wide Entra group with that name for Rota.

Instead, an authorised database administrator must map that PostgreSQL role
on each Rota non-production server to the object ID of the Entra group
`DTS CFT Rota DB Access Writer`. Azure Database for PostgreSQL supports a
role name that differs from its linked Entra group's display name when the
principal is created by object ID. The generic role name is local to each
Rota PostgreSQL server; its Entra membership remains Rota-specific.

## Before applying Rota Terraform

1. Ensure both Entra groups exist: `DTS CFT Rota DB Access Writer` for
   non-production and `DTS JIT Access rota DB Writer SC` for production.
   Record the non-production group's object ID from Entra ID.
2. For **each** Rota non-production PostgreSQL server (`rota-psql-dapdb-<env>`
   and `rota-psql-dopdb-<env>`), connect as a Microsoft Entra database
   administrator to the **`postgres`** database. Check whether the role
   already exists and, if mapped, which Entra object ID it uses:

   ```sql
   SELECT rolname FROM pg_catalog.pg_roles
   WHERE rolname = 'DTS CFT DB Access Writer';

   SELECT * FROM pg_catalog.pgaadauth_list_principals(false)
   WHERE rolename = 'DTS CFT DB Access Writer';
   ```

   If the role does not exist, create it using the *verified* Rota group
   object ID (replace the placeholder):

   ```sql
   SELECT pg_catalog.pgaadauth_create_principal_with_oid(
     'DTS CFT DB Access Writer',
     '<DTS CFT Rota DB Access Writer object ID>',
     'group',
     false,
     false
   );
   ```

   If the role already exists but is unmapped or mapped to another object ID,
   **stop** and resolve that with the database administrator. Do not silently
   replace an existing mapping.
3. Confirm `pgaadauth_list_principals(false)` now reports the Rota group
   object ID for `DTS CFT DB Access Writer` on **both** servers.
4. Only then apply the Rota Terraform change. The module sees the existing
   PostgreSQL role and skips its display-name lookup, then grants the role
   writer access to `mojdb` or `optimiserdb` as appropriate. The
   `force_user_permissions_trigger` value makes the module's permissions
   step rerun even if an earlier apply recorded it as complete after the
   lookup error. It also reruns the existing production permissions step,
   so the production group must exist before applying there.
5. Verify the expected schema/table/sequence grants and test a connection
   using a member of the Rota Entra writer group. Membership should be
   managed through an approved access process.

Production needs no object-ID alias: the module maps the Rota-specific Entra
group by its exact display name. Keep `enable_write_group_access = true` in
both module calls.

This procedure changes database state outside Terraform and must be executed
by the authorised database administrator before this Terraform PR is merged.
It does not change the shared module or add Terraform resources outside the
approved allowlist. Recheck the module's role-existence guard when upgrading
the module, as that guard is what allows the non-production alias to work.

Reference: [Microsoft's guidance on creating a PostgreSQL role from an Entra
object ID](https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users#create-a-role-by-using-the-microsoft-entra-id-object-identifier).
