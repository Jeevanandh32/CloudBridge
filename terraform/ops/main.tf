# Ops: budgets on both clouds ($15 AWS + $10 Azure = $25 total).
# The older backstop budgets (cloudbridge-backstop-50 on AWS, cloudbridge-budget-50 on Azure)
# were made by hand and are not managed here.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # State lives in the same S3 bucket as the other layers
  backend "s3" {
    key = "ops.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "alert_email" {
  description = "Where budget alerts go (set in terraform.tfvars, which is git-ignored)"
  type        = string
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "ops" }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers were registered once by hand
  resource_provider_registrations = "none"
}

# ==================== AWS budget ====================

resource "aws_budgets_budget" "this" {
  name         = "${var.project}-aws"
  budget_type  = "COST"
  limit_amount = "15"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # $9 actual
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 60
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # $15 actual
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # On track to pass $15 this month
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ==================== Azure budget ====================

data "azurerm_subscription" "current" {}

resource "azurerm_consumption_budget_subscription" "this" {
  name            = "${var.project}-azure"
  subscription_id = data.azurerm_subscription.current.id
  amount          = 10
  time_grain      = "Monthly"

  # Must be the first of a month. Set once at create time, then ignored so later plans
  # don't try to move it.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  lifecycle {
    ignore_changes = [time_period]
  }

  # $6 actual
  notification {
    enabled        = true
    threshold      = 60
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  # $10 actual
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
}

# ==================== Outputs ====================

output "aws_budget_name" {
  value = aws_budgets_budget.this.name
}

output "azure_budget_id" {
  value = azurerm_consumption_budget_subscription.this.id
}
