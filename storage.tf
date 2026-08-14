module "blobstore" {
  source = "git@github.com:hmcts/cnp-module-storage-account?ref=4.x"

  env                      = var.env
  storage_account_name     = substr(lower(replace("${var.product}-sa-${var.env}", "-", "")), 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.postgres_geo_redundant_backups ? "GRS" : "LRS"

  containers = [
    {
      name        = "anonymised-db-dumps"
      access_type = "private"
    }
  ]

  common_tags = local.merged_common_tags
}
