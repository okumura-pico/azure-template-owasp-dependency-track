# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Terraform IaC project deploying OWASP Dependency-Track on Azure with automated cost optimization (scheduled start/stop via Automation Account runbooks).

- Run all `terraform` commands from the `terraform/` directory.
- `terraform/terraform.tfvars` is gitignored and must be created locally (variables are defined in `variables.tf`; `subscription_id` and `pgsql_password` have no defaults).
- The Container App Environment creates its own managed resource group.
