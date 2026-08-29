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

resource "azurerm_key_vault_secret" "moj_owner_username" {
  name         = "moj-owner-username"
  value        = local.moj_owner_username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_portal_database]
}

resource "azurerm_key_vault_secret" "moj_owner_password" {
  name         = "moj-owner-password"
  value        = random_password.moj_owner.result
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_portal_database]
}

resource "azurerm_key_vault_secret" "moj_user_username" {
  name         = "moj-user-username"
  value        = local.moj_user_username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_portal_database]
}

resource "azurerm_key_vault_secret" "moj_user_password" {
  name         = "moj-user-password"
  value        = random_password.moj_user.result
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_portal_database]
}

resource "azurerm_key_vault_secret" "optimiser_owner_username" {
  name         = "optimiser-owner-username"
  value        = local.optimiser_owner_username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_optimiser_database]
}

resource "azurerm_key_vault_secret" "optimiser_owner_password" {
  name         = "optimiser-owner-password"
  value        = random_password.optimiser_owner.result
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_optimiser_database]
}

resource "azurerm_key_vault_secret" "optimiser_user_username" {
  name         = "optimiser-user-username"
  value        = local.optimiser_user_username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_optimiser_database]
}

resource "azurerm_key_vault_secret" "optimiser_user_password" {
  name         = "optimiser-user-password"
  value        = random_password.optimiser_user.result
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags

  depends_on = [terraform_data.setup_optimiser_database]
}
