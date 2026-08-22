locals {
  optimiser_owner_username       = "optimiser_owner"
  optimiser_user_username        = "optimiser_user"
  enable_cft_db_reader_access    = !contains(["prod", "prd", "production"], lower(var.env))
  cft_db_access_reader_role_name = "DTS CFT DB Access Reader"
}

resource "random_password" "optimiser_owner" {
  length           = 20
  override_special = "()-_"
}

resource "random_password" "optimiser_user" {
  length           = 20
  override_special = "()-_"
}

resource "terraform_data" "setup_optimiser_database" {
  triggers_replace = [
    module.postgresql_dopdb.instance_id,
    filesha256("${path.module}/setup-postgres.sh"),
    random_password.optimiser_owner.result,
    random_password.optimiser_user.result,
    tostring(local.enable_cft_db_reader_access),
  ]

  provisioner "local-exec" {
    command = "/usr/bin/env bash ${path.module}/setup-postgres.sh"

    environment = {
      PGHOST                     = module.postgresql_dopdb.fqdn
      DB_NAME                    = "optimiserdb"
      DB_ADMIN_USER              = module.postgresql_dopdb.username
      DB_ADMIN_PASSWORD          = module.postgresql_dopdb.password
      DB_OWNER_USER              = local.optimiser_owner_username
      DB_OWNER_PASSWORD          = random_password.optimiser_owner.result
      DB_APPLICATION_USER        = local.optimiser_user_username
      DB_APPLICATION_PASSWORD    = random_password.optimiser_user.result
      ENABLE_CFT_READER_ACCESS   = tostring(local.enable_cft_db_reader_access)
      CFT_DB_ACCESS_READER_ROLE  = local.cft_db_access_reader_role_name
    }
  }

  depends_on = [module.postgresql_dopdb]
}
