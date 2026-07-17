module "key_vault" {
  source                  = "git@github.com:hmcts/cnp-module-key-vault?ref=master"
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
