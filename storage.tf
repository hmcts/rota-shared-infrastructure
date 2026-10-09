module "blobstore" {
  source = "git@github.com:hmcts/cnp-module-storage-account?ref=4.x"

  env                      = var.env
  storage_account_name     = substr(lower(replace("${var.product}-sa-${var.env}", "-", "")), 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.postgres_geo_redundant_backups ? "GRS" : "LRS"
  # Azure DevOps agents in hmcts-cftptl-agent-pool run on these CFT PTL AKS subnets.
  sa_subnets = [
    "/subscriptions/1baf5470-1c3e-40d3-a6f7-74bfbce4b348/resourceGroups/cft-ptl-network-rg/providers/Microsoft.Network/virtualNetworks/cft-ptl-vnet/subnets/aks-00",
    "/subscriptions/1baf5470-1c3e-40d3-a6f7-74bfbce4b348/resourceGroups/cft-ptl-network-rg/providers/Microsoft.Network/virtualNetworks/cft-ptl-vnet/subnets/aks-01",
  ]

  common_tags = local.merged_common_tags
}

resource "azurerm_storage_container" "anonymised_db_dumps" {
  name                  = "anonymised-db-dumps"
  storage_account_id    = module.blobstore.storageaccount_id
  container_access_type = "private"
}

# data "azuread_service_principal" "dump_distribution" {
#   # Service principal behind the DTS-CFTPTL-INTSVC Azure DevOps connection.
#   display_name = "DTS Bootstrap (sub:dts-cftptl-intsvc)"
# }

# resource "azurerm_role_assignment" "dump_distribution" {
#   scope                = "${module.blobstore.storageaccount_id}/blobServices/default/containers/${azurerm_storage_container.anonymised_db_dumps.name}"
#   role_definition_name = var.env == "prod" ? "Storage Blob Data Reader" : "Storage Blob Data Contributor"
#   principal_id         = data.azuread_service_principal.dump_distribution.object_id
# }
