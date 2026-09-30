locals {
  postgresql_diagnostic_log_categories = toset([
    "PostgreSQLLogs",
    "PostgreSQLFlexDatabaseXacts",
    "PostgreSQLFlexQueryStoreRuntime",
    "PostgreSQLFlexQueryStoreWaitStats",
    "PostgreSQLFlexSessions",
    "PostgreSQLFlexTableStats",
  ])

  postgresql_log_analytics_workspace_ids = {
    nonprod = "/subscriptions/1c4f0704-a29e-403d-b719-b90c34ef14c9/resourceGroups/oms-automation/providers/Microsoft.OperationalInsights/workspaces/hmcts-nonprod"
    prod    = "/subscriptions/8999dec3-0104-4a27-94ee-6588559729d1/resourceGroups/oms-automation/providers/Microsoft.OperationalInsights/workspaces/hmcts-prod"
  }

  postgresql_log_analytics_workspace_id = local.postgresql_log_analytics_workspace_ids[var.env == "prod" ? "prod" : "nonprod"]

  postgresql_servers_with_diagnostics = var.pgsql_enable_query_diagnostics ? {
    dapdb = module.postgresql_dapdb.instance_id
    dopdb = module.postgresql_dopdb.instance_id
  } : {}
}

resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  for_each = local.postgresql_servers_with_diagnostics

  name                           = "log_to_azure_monitor"
  target_resource_id             = each.value
  log_analytics_workspace_id     = local.postgresql_log_analytics_workspace_id
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
