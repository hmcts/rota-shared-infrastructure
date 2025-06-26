module "postgresql" {

  providers = {
    azurerm.postgres_network = azurerm.postgres_network
  }
  
  source = "git@github.com:hmcts/terraform-module-postgresql-flexible?ref=master"
  env    = var.env

  product       = var.product
  component     = var.component
  business_area = "sds" # sds or cft

  # The original subnet is full, this is required to use the new subnet for new databases
  subnet_suffix = "expanded"

  pgsql_databases = [
    {
      name : "rota"
    }
  ]

  pgsql_sku     = "GP_Standard_D2ds_v4"
  pgsql_version = "16"

  geo_redundant_backups = var.postgres_geo_redundant_backups

  # Changing the value of the trigger_password_reset variable will trigger Terraform to rotate the password of the pgadmin user.
  trigger_password_reset = "any value here"
  
  # The ID of the principal to be granted admin access to the database server.
  # On Jenkins it will be injected for you automatically as jenkins_AAD_objectId.
  # Otherwise change the below:
  admin_user_object_id = var.jenkins_AAD_objectId
  
  common_tags = var.common_tags
}