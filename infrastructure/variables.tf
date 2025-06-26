variable "postgres_geo_redundant_backups" {
  default = false
}

variable "aks_subscription_id" {} # provided by the Jenkins library, ADO users will need to specify this

variable "common_tags" {
  type = map(string)
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
  default = ""
}
