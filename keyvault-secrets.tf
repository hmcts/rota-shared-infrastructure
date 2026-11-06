resource "azurerm_key_vault_secret" "application_insights_connection_string" {
  name         = "application-insights-connection-string"
  value        = module.application_insights.connection_string
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "application_insights_instrumentation_key" {
  name         = "application-insights-instrumentation-key"
  value        = module.application_insights.instrumentation_key
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "storage_account_primary_access_key" {
  name         = "storage-account-primary-access-key"
  value        = module.blobstore.storageaccount_primary_access_key
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "random_password" "anonymised_db_dump_encryption" {
  count = var.env == "prod" ? 1 : 0

  length  = 64
  special = false

  # Retain the key needed to decrypt existing backups.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault_secret" "anonymised_db_dump_encryption_password" {
  count = var.env == "prod" ? 1 : 0

  name         = "anonymised-db-dump-encryption-password"
  value        = random_password.anonymised_db_dump_encryption[0].result
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault_secret" "postgresql_admin_username" {
  name         = "postgresql-admin-username"
  value        = module.postgresql_dapdb.username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "postgresql_admin_password" {
  name         = "postgresql-admin-password"
  value        = module.postgresql_dapdb.password
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "postgresql_fqdn" {
  name         = "postgresql-fqdn"
  value        = module.postgresql_dapdb.fqdn
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dapdb_postgresql_admin_username" {
  name         = "dapdb-postgresql-admin-username"
  value        = module.postgresql_dapdb.username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dapdb_postgresql_admin_password" {
  name         = "dapdb-postgresql-admin-password"
  value        = module.postgresql_dapdb.password
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dapdb_postgresql_fqdn" {
  name         = "dapdb-postgresql-fqdn"
  value        = module.postgresql_dapdb.fqdn
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dopdb_postgresql_admin_username" {
  name         = "dopdb-postgresql-admin-username"
  value        = module.postgresql_dopdb.username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dopdb_postgresql_admin_password" {
  name         = "dopdb-postgresql-admin-password"
  value        = module.postgresql_dopdb.password
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "dopdb_postgresql_fqdn" {
  name         = "dopdb-postgresql-fqdn"
  value        = module.postgresql_dopdb.fqdn
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}
