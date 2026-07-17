module "key_vault" {
  # Pin to a revision compatible with this repository's AzureRM 4.34 provider constraint.
  source                  = "git@github.com:hmcts/cnp-module-key-vault?ref=7fa53b9e5fbd2710a6c835101fe37d7dbe8c4067"
  name                    = "${var.product}-shared-${var.env}"
  product                 = var.product
  env                     = var.env
  object_id               = var.jenkins_AAD_objectId
  jenkins_object_id       = data.azurerm_user_assigned_identity.jenkins.principal_id
  resource_group_name     = azurerm_resource_group.rg.name
  product_group_name      = "CPP Rota"
  common_tags             = local.merged_common_tags
  create_managed_identity = true
}

data "azurerm_user_assigned_identity" "jenkins" {
  name                = "jenkins-${var.env}-mi"
  resource_group_name = "managed-identities-${var.env}-rg"
}
