##
## 予算
##
resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "${var.prefix}-budget"
  resource_group_id = azurerm_resource_group.this.id
  amount            = local.budget_amount
  time_grain        = "BillingMonth"

  time_period {
    start_date = local.now
    end_date   = "2036-12-31"
  }

  notification {
    operator       = "EqualTo"
    threshold      = 50.0
    threshold_type = "Actual"

    contact_emails = var.budget_notification_emails
  }

  filter {
    dimension {
      name = "ResourceId"
      values = [
        azurerm_resource_group.this.id,
        "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${azurerm_container_app_environment.this.infrastructure_resource_group_name}"
      ]
    }
  }
}
