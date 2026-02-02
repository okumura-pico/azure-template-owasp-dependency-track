##
## リソースグループ
##
resource "azurerm_resource_group" "this" {
  location = var.location
  name     = "${var.prefix}-rg"
}

##
## Automationアカウント
##
resource "azurerm_automation_account" "this" {
  name                = "${var.prefix}-aa"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }
}

##
## AutomationアカウントにContributorロール割当 リソースグループに制限
##
resource "azurerm_role_assignment" "aa_contributor_on_container_rg" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.this.identity[0].principal_id
}

##
## Automationスケジュール 平日朝と平日夜
##
resource "azurerm_automation_schedule" "workday_morning" {
  name                    = "${var.prefix}-workday-morning"
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Week"
  interval                = 1
  timezone                = "Asia/Tokyo"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  start_time              = "2026-01-01T08:50:00+09:00"
}
resource "azurerm_automation_schedule" "evening" {
  name                    = "${var.prefix}-evening"
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Day"
  interval                = 1
  timezone                = "Asia/Tokyo"
  start_time              = "2026-01-01T18:50:00+09:00"
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
resource "azurerm_subnet" "pgsql" {
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  name                 = "pgsql"
  address_prefixes     = ["10.1.0.0/24"]
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
  address_prefixes     = ["10.1.1.0/24"]
}

##
## Private DNS zone
## PostgreSQLサーバをpublicにしないため必要
##
resource "azurerm_private_dns_zone" "this" {
  resource_group_name = azurerm_resource_group.this.name
  name                = "${var.prefix}.postgres.database.azure.com"
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "${var.prefix}.internal"
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
  resource_group_name   = azurerm_resource_group.this.name
  depends_on            = [azurerm_subnet.pgsql]
}

##
## PostgreSQL
##
resource "azurerm_postgresql_flexible_server" "this" {
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  name                          = module.naming.postgresql_server.name_unique
  version                       = local.pgsql_version
  administrator_login           = var.pgsql_login
  administrator_password        = var.pgsql_password
  storage_mb                    = local.pgsql_storage_mb
  sku_name                      = var.pgsql_sku_name
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.pgsql.id
  private_dns_zone_id           = azurerm_private_dns_zone.this.id
  backup_retention_days         = "7"
  depends_on                    = [azurerm_private_dns_zone_virtual_network_link.this]
}
resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = "${var.prefix}-db"
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  # prevent the possibility of accidental data loss
  lifecycle {
    prevent_destroy = true
  }
}

##
## Container Instances
##
resource "azurerm_container_group" "this" {
  name                        = "${var.prefix}-aci"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.this.name
  os_type                     = "Linux"
  ip_address_type             = "Private"
  subnet_ids                  = [azurerm_subnet.container.id]
  dns_name_label_reuse_policy = "SubscriptionReuse"

  exposed_port = [
    {
      port     = 8080
      protocol = "TCP"
    }
  ]

  container {
    name   = "apiserver"
    image  = local.dtrack_apiserver_image_tag
    cpu    = "2.0"
    memory = "8.0"

    environment_variables = {
      ALPINE_DATABASE_MODE = "external"
      ALPINE_DATABASE_URL  = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}/${azurerm_postgresql_flexible_server_database.this.name}"
    }
    secure_environment_variables = {
      ALPINE_DATABASE_USERNAME = var.pgsql_login
      ALPINE_DATABASE_PASSWORD = var.pgsql_password
    }
  }

  container {
    name   = "frontend"
    image  = local.dtrack_frontend_image_tag
    cpu    = "1.0"
    memory = "1.0"

    ports {
      port     = 8080
      protocol = "TCP"
    }

    environment_variables = {
      API_BASE_URL = "http://localhost:8081"
    }
  }
}
##
## Application Gateway
##
resource "azurerm_application_gateway" "this" {
  name                = "${var.prefix}-agw"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location

  backend_address_pool {
    name  = "backendPool"
    fqdns = [azurerm_container_group.this.fqdn]
  }

  backend_http_settings {
    name                  = "httpSettings"
    cookie_based_affinity = "Disabled"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 20
  }

  frontend_ip_configuration {
    name      = "frontendIP"
    subnet_id = azurerm_subnet.container.id
  }

  frontend_port {
    name = "frontendPort"
    port = 443
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.container.id
  }

  http_listener {
    name                           = "httpListener"
    frontend_ip_configuration_name = "frontendIP"
    frontend_port_name             = "frontendPort"
    protocol                       = "Https"
  }

  request_routing_rule {
    name                       = "routingRule"
    rule_type                  = "Basic"
    http_listener_name         = "httpListener"
    backend_address_pool_name  = "backendPool"
    backend_http_settings_name = "httpSettings"
  }

  sku {
    name     = "Basic"
    tier     = "Basic"
    capacity = 1
  }
}

##
## 夜間休日はいろいろ動かさない
##
# 起動
resource "azurerm_automation_runbook" "start" {
  name                    = "${var.prefix}-start"
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = true
  log_progress            = true
  runbook_type            = "PowerShell"

  # 参考リンク
  # https://learn.microsoft.com/en-us/powershell/module/az.postgresql/start-azpostgresqlflexibleserver?view=azps-15.2.0
  # https://shisho.dev/dojo/providers/azurerm/Automation/azurerm-automation-job-schedule/
  # https://learn.microsoft.com/en-us/powershell/module/az.network/start-azapplicationgateway?view=azps-15.2.0

  content = <<_EOS_
param(
  [Parameter(Mandatory=$true)] [string] $SubscriptionId,
  [Parameter(Mandatory=$true)] [string] $ResourceGroup,

  # ACI
  [Parameter(Mandatory=$true)] [string] $AciContainerGroupName,

  # Application Gateway
  [Parameter(Mandatory=$true)] [string] $AppGwName,

  # PostgreSQL Flexible Server
  [Parameter(Mandatory=$true)] [string] $PgFlexibleServerName,

  # ACI Start API version (from REST docs)
  [string] $AciApiVersion = "2025-09-01"
)

Write-Output "Logging in with Managed Identity..."
Connect-AzAccount -Identity | Out-Null
Set-AzContext -Subscription $SubscriptionId | Out-Null

Write-Output "Starting PostgreSQL Flexible Server '$PgFlexibleServerName' in RG '$ResourceGroup'..."
Start-AzPostgreSqlFlexibleServer -Name $PgFlexibleServerName -ResourceGroupName $ResourceGroup | Out-Null
Write-Output "PostgreSQL Flexible Server start submitted."

$aciPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerInstance/containerGroups/$AciContainerGroupName/start?api-version=$AciApiVersion"
Write-Output "Starting ACI container group '$AciContainerGroupName' in RG '$ResourceGroup'..."
$aciResp = Invoke-AzRestMethod -Method POST -Path $aciPath
Write-Output "ACI start request status code: $($aciResp.StatusCode)"

Write-Output "Starting Application Gateway '$AppGwName' in RG '$ResourceGroup'..."
$appGw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup
Start-AzApplicationGateway -ApplicationGateway $appGw | Out-Null
Write-Output "Application Gateway start submitted."

Write-Output "Done."
  _EOS_
}
# 停止
resource "azurerm_automation_runbook" "stop" {
  name                    = "${var.prefix}-stop"
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = true
  log_progress            = true
  runbook_type            = "PowerShell"
  content                 = <<_EOS_
param(
  [Parameter(Mandatory=$true)] [string] $SubscriptionId,
  [Parameter(Mandatory=$true)] [string] $ResourceGroup,

  # ACI
  [Parameter(Mandatory=$true)] [string] $AciContainerGroupName,

  # Application Gateway
  [Parameter(Mandatory=$true)] [string] $AppGwName,

  # PostgreSQL Flexible Server
  [Parameter(Mandatory=$true)] [string] $PgFlexibleServerName,

  # ACI Start API version (from REST docs)
  [string] $AciApiVersion = "2025-09-01"
)

Write-Output "Logging in with Managed Identity..."
Connect-AzAccount -Identity | Out-Null
Set-AzContext -Subscription $SubscriptionId | Out-Null

Write-Output "Stoping PostgreSQL Flexible Server '$PgFlexibleServerName' in RG '$ResourceGroup'..."
Stop-AzPostgreSqlFlexibleServer -Name $PgFlexibleServerName -ResourceGroupName $ResourceGroup | Out-Null
Write-Output "PostgreSQL Flexible Server stop submitted."

$aciPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerInstance/containerGroups/$AciContainerGroupName/stop?api-version=$AciApiVersion"
Write-Output "Stoping ACI container group '$AciContainerGroupName' in RG '$ResourceGroup'..."
$aciResp = Invoke-AzRestMethod -Method POST -Path $aciPath
Write-Output "ACI stop request status code: $($aciResp.StatusCode)"

Write-Output "Stoping Application Gateway '$AppGwName' in RG '$ResourceGroup'..."
$appGw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroup
Stop-AzApplicationGateway -ApplicationGateway $appGw | Out-Null
Write-Output "Application Gateway stop submitted."

Write-Output "Done."
  _EOS_
}
# スケジュールと紐付け
resource "azurerm_automation_job_schedule" "start" {
  automation_account_name = azurerm_automation_account.this.name
  resource_group_name     = azurerm_resource_group.this.name
  runbook_name            = azurerm_automation_runbook.start.name
  schedule_name           = azurerm_automation_schedule.workday_morning.name

  parameters = {
    SubscriptionId        = var.subscription_id
    ResourceGroup         = azurerm_resource_group.this.name
    AciContainerGroupName = azurerm_container_group.this.name
    AppGwName             = azurerm_application_gateway.this.name
    PgFlexibleServerName  = azurerm_postgresql_flexible_server.this.name
  }
}
resource "azurerm_automation_job_schedule" "stop" {
  automation_account_name = azurerm_automation_account.this.name
  resource_group_name     = azurerm_resource_group.this.name
  runbook_name            = azurerm_automation_runbook.stop.name
  schedule_name           = azurerm_automation_schedule.evening.name

  parameters = {
    SubscriptionId        = var.subscription_id
    ResourceGroup         = azurerm_resource_group.this.name
    AciContainerGroupName = azurerm_container_group.this.name
    AppGwName             = azurerm_application_gateway.this.name
    PgFlexibleServerName  = azurerm_postgresql_flexible_server.this.name
  }
}
