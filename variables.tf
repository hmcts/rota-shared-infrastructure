variable "postgres_geo_redundant_backups" {
  description = "Enable geo-redundant backups for both PostgreSQL servers."
  type        = bool
  default     = false
}

variable "dapdb_pgsql_sku" {
  description = "SKU for the DAPDB PostgreSQL Flexible Server. Defaults to the development tier."
  type        = string
  default     = "GP_Standard_D4ds_v5"
}

variable "dapdb_pgsql_storage_mb" {
  description = "Storage in MB for the DAPDB PostgreSQL Flexible Server. Defaults to the development tier."
  type        = number
  default     = 65536
}

variable "dapdb_pgsql_storage_tier" {
  description = "Storage tier for the DAPDB PostgreSQL Flexible Server. Defaults to the development tier."
  type        = string
  default     = "P6"
}

variable "dopdb_pgsql_sku" {
  description = "SKU for the DOPDB PostgreSQL Flexible Server."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "dopdb_pgsql_storage_mb" {
  description = "Storage in MB for the DOPDB PostgreSQL Flexible Server."
  type        = number
  default     = 65536
}

variable "dopdb_pgsql_storage_tier" {
  description = "Storage tier for the DOPDB PostgreSQL Flexible Server."
  type        = string
  default     = "P6"
}

variable "pgsql_backup_retention_days" {
  description = "Backup retention in days for both PostgreSQL Flexible Servers. Defaults to the development tier."
  type        = number
  default     = 7
}

variable "pgsql_high_availability" {
  description = "Enable zone-redundant high availability for both PostgreSQL Flexible Servers. Defaults to the development tier."
  type        = bool
  default     = false
}

variable "pgsql_enable_query_diagnostics" {
  description = "Enable query store and wait sampling diagnostics on both PostgreSQL Flexible Servers. Defaults to the development tier."
  type        = bool
  default     = false
}

variable "pgsql_logfiles_download_enable" {
  description = "Enable server log file downloads on both PostgreSQL Flexible Servers."
  type        = string
  default     = "on"
}

variable "aks_subscription_id" {} # provided by the Jenkins library, ADO users will need to specify this

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "built_from" {
  description = "Repository URL or name used for tagging resources"
  default     = "https://github.com/hmcts/rota-shared-infrastructure"
}

variable "env" {
  description = "The deployment environment (sandbox, aat, prod etc..)"
}

variable "jenkins_AAD_objectId" {
  description = "The object ID of the user to be granted access to the key vault"
}

variable "location" {
  description = "The location where you would like to deploy your infrastructure"
  default     = "UK South"
}

variable "product" {}

variable "component" {
  default = "shared-infra"
}
