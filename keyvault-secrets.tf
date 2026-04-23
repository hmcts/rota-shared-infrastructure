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
  value        = module.postgresql.username
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "postgresql_admin_password" {
  name         = "postgresql-admin-password"
  value        = module.postgresql.password
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}

resource "azurerm_key_vault_secret" "postgresql_fqdn" {
  name         = "postgresql-fqdn"
  value        = module.postgresql.fqdn
  key_vault_id = module.key_vault.key_vault_id

  tags = local.merged_common_tags
}
