# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terraform IaC project deploying OWASP Dependency-Track on Azure with automated cost optimization (scheduled start/stop).

## Commands

All commands run from `terraform/` directory:

```bash
terraform init      # Initialize (required first time or after provider changes)
terraform plan      # Preview changes
terraform apply     # Apply infrastructure
terraform destroy   # Destroy (database has prevent_destroy)
terraform fmt       # Format code
terraform validate  # Validate configuration
```

## Architecture

### Network Topology

```
VNET (10.1.0.0/16)
├── default subnet (10.1.0.0/24)
├── pgsql subnet (10.1.16.0/24) - Delegated to PostgreSQL Flexible Server
└── container subnet (10.1.32.0/23) - Delegated to Microsoft.App/environments
```

### Resource Dependencies

1. **PostgreSQL Flexible Server** - Private access only via Private DNS Zone (with diagnostic logging)
2. **Container Apps Environment** - Consumption workload profile, connected to Log Analytics
3. **Container Apps** (scale-to-zero enabled):
   - API (`dependencytrack/apiserver:latest`, port 8080, 2.25 CPU/4.5Gi) - External ingress
   - Frontend (`dependencytrack/frontend:latest`, port 8080, 0.5 CPU/1Gi) - External ingress
4. **Automation Account** - Scheduled PostgreSQL start/stop via PowerShell runbooks

### Cost Optimization

- Container Apps use `min_replicas = 0` for automatic scale-to-zero
- **Morning schedule**: Weekdays 08:50 JST - starts PostgreSQL
- **Evening schedule**: Daily 18:50 JST - stops PostgreSQL
- Uses SystemAssigned managed identity with Contributor role scoped to resource group

### State Management

Remote backend in Azure Storage:
- Storage Account: `tfstatearc` (Resource Group: `terraform-rg`)
- Container: `owasp-dependency-track`
- State file: `dtrack-live.tfstate`

## Required Variables

Create `terraform/terraform.tfvars` (gitignored):

```hcl
subscription_id = "your-subscription-id"
prefix          = "dtrack"
location        = "japaneast"
pgsql_password  = "secure-password"
pgsql_login     = "postgres"        # optional, defaults to postgres
pgsql_sku_name  = "B_Standard_B2ms" # optional
```

## Key Configuration

- PostgreSQL: version 17, 32GB storage, 7-day backup retention
- Naming module (`Azure/naming/azurerm`) generates unique resource names
- Log Analytics Workspace: 30-day retention
- Container App Environment creates its own managed resource group
