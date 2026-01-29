# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    corefunc = {
      source = "northwood-labs/corefunc"
    }
  }

  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstatevault"
    container_name       = "tfstate-live"
    # key: The name of the state store file to be created.
    key = "owasp-dependency-tracker.tfstate"
  }
}
