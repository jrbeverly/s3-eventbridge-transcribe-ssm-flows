variable "aws_region" {
  description = "AWS region in which to run the experiment."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name, such as us-east-1."
  }
}

variable "environment" {
  description = "Short environment name used to identify and tag experimental resources."
  type        = string
  default     = "experiment"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.environment))
    error_message = "environment must be 3-32 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "project_name" {
  description = "Stable project name applied to resources as an operational tag."
  type        = string
  default     = "s3-eventbridge-transcribe-ssm-flows"

  validation {
    condition     = length(trimspace(var.project_name)) > 0 && length(var.project_name) <= 256
    error_message = "project_name must contain between 1 and 256 characters."
  }
}

variable "additional_tags" {
  description = "Additional operational tags. The required common tags take precedence."
  type        = map(string)
  default     = {}
}

variable "readiness_reconciliation_interval_minutes" {
  description = "Interval in minutes between fallback scans for source objects whose readiness event was delayed or missed."
  type        = number
  default     = 15

  validation {
    condition     = var.readiness_reconciliation_interval_minutes >= 5 && var.readiness_reconciliation_interval_minutes <= 1440 && floor(var.readiness_reconciliation_interval_minutes) == var.readiness_reconciliation_interval_minutes
    error_message = "readiness_reconciliation_interval_minutes must be a whole number from 5 through 1440."
  }
}

variable "confluence_base_url" {
  description = "Path-free Confluence Cloud origin used by the page publication adapter."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.atlassian\\.net$", var.confluence_base_url))
    error_message = "confluence_base_url must be a path-free https://*.atlassian.net origin."
  }
}

variable "confluence_space_id" {
  description = "Opaque Confluence space ID in which reconciled pages are stored."
  type        = string

  validation {
    condition     = length(trimspace(var.confluence_space_id)) > 0
    error_message = "confluence_space_id must not be empty."
  }
}

variable "confluence_credentials_secret_arn" {
  description = "ARN of an existing Secrets Manager secret whose JSON value contains email and api_token."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$", var.confluence_credentials_secret_arn))
    error_message = "confluence_credentials_secret_arn must be a Secrets Manager secret ARN."
  }
}
