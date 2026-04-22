module "application_insights" {
  source = "git@github.com:hmcts/terraform-module-application-insights?ref=4.x"

  product = var.product
  env     = var.env

  resource_group_name = azurerm_resource_group.rg.name

  common_tags         = module.tags.common_tags
  sampling_percentage = 100
}
