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
    resource_group_name  = "terraform-rg"
    storage_account_name = "tfstatearc"
    container_name       = "owasp-dependency-track"
    # key: The name of the state store file to be created.
    key = "dtrack-live.tfstate"
  }
}
