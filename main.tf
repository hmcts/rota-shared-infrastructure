locals {
  environment_tag_map = {
    aat      = "staging"
    stg      = "staging"
    staging  = "staging"
    demo     = "demo"
    ithc     = "ITHC"
    test     = "testing"
    perftest = "testing"
    prod     = "production"
    prd      = "production"
    dev      = "development"
    sandbox  = "sandbox"
  }

  required_common_tags = {
    application  = "rota"
    businessArea = "CFT"
    builtFrom    = var.built_from
    environment  = lookup(local.environment_tag_map, lower(var.env), var.env)
  }

  merged_common_tags = merge(var.common_tags, local.required_common_tags)
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.product}-shared-infra-${var.env}"
  location = var.location

  tags = local.merged_common_tags
}
