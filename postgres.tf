locals {
  pgsql_query_diagnostics_configuration = var.pgsql_enable_query_diagnostics ? {
    "metrics.collector_database_activity"   = "on"
    "metrics.autovacuum_diagnostics"        = "on"
    "pg_qs.query_capture_mode"              = "top"
    "pgms_wait_sampling.query_capture_mode" = "all"
    track_io_timing                         = "on"
  } : {}

  dapdb_postgresql_configuration = merge(
    {
      autovacuum_analyze_scale_factor       = "0.01"
      autovacuum_vacuum_insert_scale_factor = "0.01"
      autovacuum_vacuum_scale_factor        = "0.01"
      backslash_quote                       = "safe_encoding"
      effective_io_concurrency              = "32"
      idle_in_transaction_session_timeout   = "1800000"
      log_duration                          = "off"
      log_error_verbosity                   = "default"
      log_lock_waits                        = "on"
      log_min_duration_statement            = "5000"
      log_min_messages                      = "warning"
      max_connections                       = "256"
      max_prepared_transactions             = "0"
      random_page_cost                      = "1.1"
      work_mem                              = "131072"
      "azure.extensions"                    = "PG_BUFFERCACHE,PG_STAT_STATEMENTS"
      "logfiles.download_enable"            = var.pgsql_logfiles_download_enable
      "logfiles.retention_days"             = "7"
    },
    local.pgsql_query_diagnostics_configuration
  )

  dopdb_postgresql_configuration = merge(
    {
      backslash_quote                     = "safe_encoding"
      idle_in_transaction_session_timeout = "1800000"
      log_duration                        = "off"
      log_error_verbosity                 = "default"
      log_lock_waits                      = "on"
      log_min_duration_statement          = "15000"
      log_min_messages                    = "warning"
      max_connections                     = "256"
      max_prepared_transactions           = "0"
      "azure.extensions"                  = "PG_BUFFERCACHE,PG_STAT_STATEMENTS"
      "logfiles.download_enable"          = var.pgsql_logfiles_download_enable
      "logfiles.retention_days"           = "7"
    },
    local.pgsql_query_diagnostics_configuration
  )
}

module "postgresql_dapdb" {

  providers = {
    azurerm.postgres_network = azurerm.postgres_network
  }

  source = "git@github.com:hmcts/terraform-module-postgresql-flexible?ref=master"
  env    = var.env

  name                = "rota-psql-dapdb"
  product             = var.product
  component           = var.component
  resource_group_name = azurerm_resource_group.rg.name
  business_area       = "cft" # sds or cft
  subnet_suffix       = "expanded"

  pgsql_databases = [
    {
      name : "mojdb"
    }
  ]
  pgsql_sku             = var.dapdb_pgsql_sku
  pgsql_storage_mb      = var.dapdb_pgsql_storage_mb
  pgsql_storage_tier    = var.dapdb_pgsql_storage_tier
  pgsql_version         = "15"
  backup_retention_days = var.pgsql_backup_retention_days
  auto_grow_enabled     = true
  high_availability     = var.pgsql_high_availability

  pgsql_server_configuration = [
    for name, value in local.dapdb_postgresql_configuration : {
      name  = name
      value = value
    }
  ]

  geo_redundant_backups = var.postgres_geo_redundant_backups

  trigger_password_reset = "any value here"

  admin_user_object_id = var.jenkins_AAD_objectId

  common_tags = local.merged_common_tags
}

module "postgresql_dopdb" {

  providers = {
    azurerm.postgres_network = azurerm.postgres_network
  }

  source = "git@github.com:hmcts/terraform-module-postgresql-flexible?ref=master"
  env    = var.env

  name                = "rota-psql-dopdb"
  product             = var.product
  component           = var.component
  resource_group_name = azurerm_resource_group.rg.name
  business_area       = "cft" # sds or cft
  subnet_suffix       = "expanded"

  pgsql_databases = [
    {
      name : "optimisationdb"
    },
    {
      name : "persistdb"
    }
  ]
  pgsql_sku             = var.dopdb_pgsql_sku
  pgsql_storage_mb      = var.dopdb_pgsql_storage_mb
  pgsql_storage_tier    = var.dopdb_pgsql_storage_tier
  pgsql_version         = "15"
  backup_retention_days = var.pgsql_backup_retention_days
  auto_grow_enabled     = true
  high_availability     = var.pgsql_high_availability

  pgsql_server_configuration = [
    for name, value in local.dopdb_postgresql_configuration : {
      name  = name
      value = value
    }
  ]

  geo_redundant_backups = var.postgres_geo_redundant_backups

  trigger_password_reset = "any value here"

  admin_user_object_id = var.jenkins_AAD_objectId

  common_tags = local.merged_common_tags
}
