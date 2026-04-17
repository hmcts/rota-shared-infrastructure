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
