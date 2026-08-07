output "application_insights_name" {
  value = module.application_insights.name
}

output "application_insights_id" {
  value = module.application_insights.id
}

output "application_insights_instrumentation_key" {
  value     = module.application_insights.instrumentation_key
  sensitive = true
}

output "application_insights_connection_string" {
  value     = module.application_insights.connection_string
  sensitive = true
}

output "key_vault_name" {
  value = module.key_vault.key_vault_name
}

output "key_vault_id" {
  value = module.key_vault.key_vault_id
}

output "postgresql_fqdn" {
  description = "Deprecated compatibility output for the DAPDB PostgreSQL server."
  value       = module.postgresql_dapdb.fqdn
}

output "dapdb_postgresql_fqdn" {
  value = module.postgresql_dapdb.fqdn
}

output "dapdb_postgresql_instance_id" {
  value = module.postgresql_dapdb.instance_id
}

output "dopdb_postgresql_fqdn" {
  value = module.postgresql_dopdb.fqdn
}

output "dopdb_postgresql_instance_id" {
  value = module.postgresql_dopdb.instance_id
}
