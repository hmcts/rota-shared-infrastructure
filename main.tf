resource "azurerm_resource_group" "rg" {
  name     = "${var.product}-shared-infra-${var.env}"
  location = var.location
}
