locals {
  optimiser_owner_username   = "optimiser_owner"
  optimiser_user_username    = "optimiser_user"
  is_postgresql_prod         = length(regexall(".*(prod).*", var.env)) > 0
  db_access_reader_role_name = local.is_postgresql_prod ? "DTS JIT Access ${var.product} DB Reader SC" : "DTS CFT DB Access Reader"
  db_access_writer_role_name = local.is_postgresql_prod ? "DTS JIT Access ${var.product} DB Writer SC" : "DTS CFT DB Access Writer"
}

resource "terraform_data" "trigger_optimiser_owner_password_reset" {
  input = "any value here"
}

resource "terraform_data" "trigger_optimiser_user_password_reset" {
  input = "any value here"
}

resource "random_password" "optimiser_owner" {
  length           = 20
  override_special = "()-_"

  lifecycle {
    replace_triggered_by = [terraform_data.trigger_optimiser_owner_password_reset]
  }
}

resource "random_password" "optimiser_user" {
  length           = 20
  override_special = "()-_"

  lifecycle {
    replace_triggered_by = [terraform_data.trigger_optimiser_user_password_reset]
  }
}

resource "terraform_data" "setup_optimiser_database" {
  triggers_replace = [
    module.postgresql_dopdb.instance_id,
    filesha256("${path.module}/scripts/database-setup/setup-postgres.sh"),
    random_password.optimiser_owner.result,
    random_password.optimiser_user.result,
    local.db_access_reader_role_name,
    local.db_access_writer_role_name,
    tostring(local.enable_read_only_group_access),
    tostring(local.enable_write_group_access),
  ]

  provisioner "local-exec" {
    command = "/usr/bin/env bash ${path.module}/scripts/database-setup/setup-postgres.sh"

    environment = {
      PGHOST                     = module.postgresql_dopdb.fqdn
      DB_NAME                    = "optimiserdb"
      DB_ADMIN_USER              = module.postgresql_dopdb.username
      DB_ADMIN_PASSWORD          = module.postgresql_dopdb.password
      DB_OWNER_USER              = local.optimiser_owner_username
      DB_OWNER_PASSWORD          = random_password.optimiser_owner.result
      DB_APPLICATION_USER        = local.optimiser_user_username
      DB_APPLICATION_PASSWORD    = random_password.optimiser_user.result
      ENABLE_DB_READER_ACCESS    = tostring(local.enable_read_only_group_access)
      ENABLE_DB_WRITER_ACCESS    = tostring(local.enable_write_group_access)
      DB_ACCESS_READER_ROLE      = local.db_access_reader_role_name
      DB_ACCESS_WRITER_ROLE      = local.db_access_writer_role_name
    }
  }

  depends_on = [module.postgresql_dopdb]
}
