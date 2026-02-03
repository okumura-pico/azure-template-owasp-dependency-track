##
## リソースグループ
##
resource "azurerm_resource_group" "this" {
  location = var.location
  name     = "${var.prefix}-rg"
}

##
## Log Analytics Workspace
##
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

##
## VNET
##
resource "azurerm_virtual_network" "this" {
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  name                = "${var.prefix}-vnet"
  address_space       = ["10.1.0.0/16"]
}
resource "azurerm_subnet" "default" {
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  name                 = "default"
  address_prefixes     = ["10.1.0.0/24"]
}
resource "azurerm_subnet" "pgsql" {
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  name                 = "pgsql"
  address_prefixes     = ["10.1.16.0/24"]

  delegation {
    name = "pgsql"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}
resource "azurerm_subnet" "container" {
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  name                 = "container"
  address_prefixes     = ["10.1.32.0/23"]

  delegation {
    name = "containerapp"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

##
## Private DNS zone
## PostgreSQLサーバをpublicにしないため必要
##
resource "azurerm_private_dns_zone" "this" {
  resource_group_name = azurerm_resource_group.this.name
  name                = "${var.prefix}.postgres.database.azure.com"

}

# VNETとPrivate DNS zoneのリンク
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "${var.prefix}.internal"
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
  resource_group_name   = azurerm_resource_group.this.name
  registration_enabled  = true

  depends_on = [
    azurerm_subnet.pgsql,
    azurerm_subnet.container
  ]
}

##
## PostgreSQL
##
resource "azurerm_postgresql_flexible_server" "this" {
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  name                          = "${var.prefix}-${module.naming.postgresql_server.name_unique}"
  version                       = local.pgsql_version
  administrator_login           = var.pgsql_login
  administrator_password        = var.pgsql_password
  storage_mb                    = local.pgsql_storage_mb
  sku_name                      = var.pgsql_sku_name
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.pgsql.id
  private_dns_zone_id           = azurerm_private_dns_zone.this.id
  backup_retention_days         = "7"
  zone                          = "1"

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.this
  ]
}
resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = "${var.prefix}-db"
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  # prevent the possibility of accidental data loss
  lifecycle {
    # prevent_destroy = true
  }
}
resource "azurerm_monitor_diagnostic_setting" "pgsql" {
  name                       = "${var.prefix}-diagnostics-pgsql"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log { category_group = "allLogs" }
  enabled_log { category_group = "audit" }
  enabled_metric { category = "allmetrics" }
}

##
## Container Apps
##
resource "azurerm_container_app_environment" "this" {
  name                       = "${var.prefix}-cae"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.container.id

  # 名前を指定しないと、applyのたびに再作成されてしまう
  infrastructure_resource_group_name = "${var.prefix}-rg-${module.naming.container_app_environment.name_unique}"

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

## APIサーバ
resource "azurerm_container_app" "api" {
  name                         = "${var.prefix}-container-api"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  template {
    min_replicas               = 0
    max_replicas               = 1
    cooldown_period_in_seconds = 180

    container {
      name   = "apiserver"
      image  = "${local.image_registry}/${local.dtrack_apiserver_image_tag}"
      cpu    = 2.25
      memory = "4.5Gi"

      env {
        name  = "ALPINE_DATABASE_MODE"
        value = "external"
      }
      env {
        name  = "ALPINE_DATABASE_URL"
        value = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.this.name}"
      }
      env {
        name  = "ALPINE_DATABASE_DRIVER"
        value = "org.postgresql.Driver"
      }
      env {
        name  = "ALPINE_DATABASE_USERNAME"
        value = var.pgsql_login
      }
      env {
        name        = "ALPINE_DATABASE_PASSWORD"
        secret_name = "db-password"
      }
    }
  }

  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8080
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  secret {
    name  = "db-password"
    value = var.pgsql_password
  }

  identity {
    type = "SystemAssigned"
  }
}

## フロントエンドサーバ
resource "azurerm_container_app" "frontend" {
  name                         = "${var.prefix}-container-frontend"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  template {
    min_replicas               = 0
    max_replicas               = 1
    cooldown_period_in_seconds = 180

    container {
      name   = "frontend"
      image  = "${local.image_registry}/${local.dtrack_frontend_image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "API_BASE_URL"
        value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
      }
    }
  }

  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    transport                  = "auto"
    target_port                = 8080

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  identity {
    type = "SystemAssigned"
  }

  depends_on = [
    azurerm_container_app.api
  ]
}
