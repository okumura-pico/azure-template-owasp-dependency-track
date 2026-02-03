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
  start_time              = local.next_0850
}
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

  content = <<_EOS_
param(
  [Parameter(Mandatory=$true)] [string] $sid,
  [Parameter(Mandatory=$true)] [string] $rgname,
  [Parameter(Mandatory=$true)] [string] $pgsrvname,
  [Parameter(Mandatory=$true)] [string] $apiAppName,
  [Parameter(Mandatory=$true)] [string] $frontendAppName
)
Connect-AzAccount -Identity
Set-AzContext -Subscription $sid

# Start PostgreSQL
Start-AzPostgreSqlFlexibleServer -Name $pgsrvname -ResourceGroupName $rgname

# Start Container Apps (set min_replicas to 1)
$apiApp = Get-AzContainerApp -Name $apiAppName -ResourceGroupName $rgname
$apiApp.TemplateScaleMinReplica = 1
$apiApp | Update-AzContainerApp

$frontendApp = Get-AzContainerApp -Name $frontendAppName -ResourceGroupName $rgname
$frontendApp.TemplateScaleMinReplica = 1
$frontendApp | Update-AzContainerApp
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

  content = <<_EOS_
param(
  [Parameter(Mandatory=$true)] [string] $sid,
  [Parameter(Mandatory=$true)] [string] $rgname,
  [Parameter(Mandatory=$true)] [string] $pgsrvname,
  [Parameter(Mandatory=$true)] [string] $apiAppName,
  [Parameter(Mandatory=$true)] [string] $frontendAppName
)
Connect-AzAccount -Identity
Set-AzContext -Subscription $sid

# Stop Container Apps (set min_replicas to 0)
$apiApp = Get-AzContainerApp -Name $apiAppName -ResourceGroupName $rgname
$apiApp.TemplateScaleMinReplica = 0
$apiApp | Update-AzContainerApp

$frontendApp = Get-AzContainerApp -Name $frontendAppName -ResourceGroupName $rgname
$frontendApp.TemplateScaleMinReplica = 0
$frontendApp | Update-AzContainerApp

# Stop PostgreSQL
Stop-AzPostgreSqlFlexibleServer -Name $pgsrvname -ResourceGroupName $rgname
_EOS_
}

# スケジュールと紐付け
resource "azurerm_automation_job_schedule" "start" {
  automation_account_name = azurerm_automation_account.this.name
  resource_group_name     = azurerm_resource_group.this.name
  runbook_name            = azurerm_automation_runbook.start.name
  schedule_name           = azurerm_automation_schedule.workday_morning.name

  parameters = {
    sid             = var.subscription_id
    rgname          = azurerm_resource_group.this.name
    pgsrvname       = azurerm_postgresql_flexible_server.this.name
    apiappname      = azurerm_container_app.api.name
    frontendappname = azurerm_container_app.frontend.name
  }
}
resource "azurerm_automation_job_schedule" "stop" {
  automation_account_name = azurerm_automation_account.this.name
  resource_group_name     = azurerm_resource_group.this.name
  runbook_name            = azurerm_automation_runbook.stop.name
  schedule_name           = azurerm_automation_schedule.evening.name

  parameters = {
    sid             = var.subscription_id
    rgname          = azurerm_resource_group.this.name
    pgsrvname       = azurerm_postgresql_flexible_server.this.name
    apiappname      = azurerm_container_app.api.name
    frontendappname = azurerm_container_app.frontend.name
  }
}
