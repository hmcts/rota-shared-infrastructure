locals {
  postgresql_diagnostic_log_categories = toset([
    "PostgreSQLLogs",
    "PostgreSQLFlexDatabaseXacts",
    "PostgreSQLFlexQueryStoreRuntime",
    "PostgreSQLFlexQueryStoreWaitStats",
    "PostgreSQLFlexSessions",
    "PostgreSQLFlexTableStats",
  ])

  production_level_postgresql_servers = var.pgsql_enable_query_diagnostics ? {
    dapdb = module.postgresql_dapdb.instance_id
    dopdb = module.postgresql_dopdb.instance_id
  } : {}
}

module "postgresql_log_analytics_workspace" {
  source = "git::https://github.com/hmcts/terraform-module-log-analytics-workspace-id?ref=master"

  count = var.pgsql_enable_query_diagnostics ? 1 : 0

  environment = var.env
}

resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  for_each = local.production_level_postgresql_servers

  name                           = "log_to_azure_monitor"
  target_resource_id             = each.value
  log_analytics_workspace_id     = module.postgresql_log_analytics_workspace[0].workspace_id
  log_analytics_destination_type = "AzureDiagnostics"

  dynamic "enabled_log" {
    for_each = local.postgresql_diagnostic_log_categories

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
