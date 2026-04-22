module "tags" {
  source = "git::https://github.com/hmcts/terraform-module-common-tags.git?ref=master"

  product     = var.product
  environment = var.env
  builtFrom   = var.built_from
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.product}-shared-infra-${var.env}"
  location = var.location

  tags = module.tags.common_tags
}
