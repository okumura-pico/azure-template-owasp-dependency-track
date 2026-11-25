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
resource "azurerm_automation_schedule" "evening" {
  name                    = "${var.prefix}-evening"
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Day"
  interval                = 1
  timezone                = "Asia/Tokyo"
  start_time              = local.next_1850
}

##
## 起動用Runbook 使うときは手動で
##
resource "azurerm_automation_runbook" "start" {
  name                    = "${var.prefix}-start"
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = false
  log_progress            = true
  runbook_type            = "PowerShell72"

  content = <<_EOS_
param(
)
$sid = "${var.subscription_id}"
$rgname = "${azurerm_resource_group.this.name}"
$pgsrvname = "${azurerm_postgresql_flexible_server.this.name}"

$ErrorActionPreference = 'Stop'

# マネージドIDでトークン取得（Azモジュールを読み込まない）
$tok = Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT `
  -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' } `
  -ContentType 'application/x-www-form-urlencoded' `
  -Body @{ resource = 'https://management.azure.com/' }
$h = @{ Authorization = "Bearer $($tok.access_token)" }
Write-Output "Access token acquired"
$base = "https://management.azure.com/subscriptions/$sid/resourceGroups/$rgname/providers"
$pgUri = "$base/Microsoft.DBforPostgreSQL/flexibleServers/$pgsrvname"

# Start PostgreSQL
$pg = Invoke-RestMethod -Headers $h -Uri "$pgUri`?api-version=2022-12-01"
if ($pg.properties.state -ne 'Ready') {
  Invoke-RestMethod -Method Post -Headers $h -ContentType 'application/json' -Body '{}' -Uri "$pgUri/start?api-version=2022-12-01" | Out-Null
  Write-Output "PostgreSQL start requested"
}

# PostgreSQLがReadyになるまで待つ（10秒間隔、最大10分）
$deadline = (Get-Date).AddMinutes(10)
$state = $pg.properties.state
while ($state -ne 'Ready' -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  $state = (Invoke-RestMethod -Headers $h -Uri "$pgUri`?api-version=2022-12-01").properties.state
  Write-Output "PostgreSQL state: $state"
}
if ($state -ne 'Ready') { throw "PostgreSQL did not become Ready (state: $state)" }

# Start Container Apps
$apps = Invoke-RestMethod -Headers $h -Uri "$base/Microsoft.App/containerApps?api-version=2024-03-01"
foreach ($a in $apps.value) {
  Invoke-RestMethod -Method Post -Headers $h -ContentType 'application/json' -Body '{}' -Uri "https://management.azure.com$($a.id)/start?api-version=2024-03-01" | Out-Null
  Write-Output "Container App start requested: $($a.name)"
}
_EOS_
}

##
## 毎晩停止する
##
resource "azurerm_automation_runbook" "stop" {
  name                    = "${var.prefix}-stop"
  location                = var.location
  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = false
  log_progress            = true
  runbook_type            = "PowerShell72"

  content = <<_EOS_
param(
)
$sid = "${var.subscription_id}"
$rgname = "${azurerm_resource_group.this.name}"
$pgsrvname = "${azurerm_postgresql_flexible_server.this.name}"

$ErrorActionPreference = 'Stop'

# マネージドIDでトークン取得（Azモジュールを読み込まない）
$tok = Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT `
  -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' } `
  -ContentType 'application/x-www-form-urlencoded' `
  -Body @{ resource = 'https://management.azure.com/' }
$h = @{ Authorization = "Bearer $($tok.access_token)" }
Write-Output "Access token acquired"
$base = "https://management.azure.com/subscriptions/$sid/resourceGroups/$rgname/providers"
$pgUri = "$base/Microsoft.DBforPostgreSQL/flexibleServers/$pgsrvname"

# Stop Container Apps
$apps = Invoke-RestMethod -Headers $h -Uri "$base/Microsoft.App/containerApps?api-version=2024-03-01"
foreach ($a in $apps.value) {
  Invoke-RestMethod -Method Post -Headers $h -ContentType 'application/json' -Body '{}' -Uri "https://management.azure.com$($a.id)/stop?api-version=2024-03-01" | Out-Null
  Write-Output "Container App stop requested: $($a.name)"
}

# Stop PostgreSQL（完了は待たない）
$pg = Invoke-RestMethod -Headers $h -Uri "$pgUri`?api-version=2022-12-01"
if ($pg.properties.state -eq 'Ready') {
  Invoke-RestMethod -Method Post -Headers $h -ContentType 'application/json' -Body '{}' -Uri "$pgUri/stop?api-version=2022-12-01" | Out-Null
  Write-Output "PostgreSQL stop requested"
} else {
  Write-Output "PostgreSQL state is $($pg.properties.state); skip stop"
}
_EOS_
}

# スケジュールと紐付け
resource "azurerm_automation_job_schedule" "stop" {
  automation_account_name = azurerm_automation_account.this.name
  resource_group_name     = azurerm_resource_group.this.name
  runbook_name            = azurerm_automation_runbook.stop.name
  schedule_name           = azurerm_automation_schedule.evening.name

  parameters = {
    sid       = var.subscription_id
    rgname    = azurerm_resource_group.this.name
    pgsrvname = azurerm_postgresql_flexible_server.this.name
  }
}
