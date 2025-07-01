module "postgresql" {

  providers = {
    azurerm.postgres_network = azurerm.postgres_network
  }
  
  source = "git@github.com:hmcts/terraform-module-postgresql-flexible?ref=master"
  env    = var.env

  name          = "rota-psql"
  product       = var.product
  component     = var.component
  resource_group_name = azurerm_resource_group.rg.name
  business_area = "sds" # sds or cft
  subnet_suffix = "expanded"

  pgsql_databases = [
    {
      name : "rota"
    }
  ]
  pgsql_sku     = "GP_Standard_D2ds_v4"
  pgsql_version = "16"
  geo_redundant_backups = var.postgres_geo_redundant_backups

  trigger_password_reset = "any value here"
  
  admin_user_object_id = var.jenkins_AAD_objectId
  
  common_tags = var.common_tags
}
