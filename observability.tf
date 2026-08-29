locals {
  operational_log_retention_days = 90
  stale_publication_minutes      = max(60, var.readiness_reconciliation_interval_minutes * 4)
  stuck_transcription_minutes    = 270

  automation_document_names = [
    aws_ssm_document.transcription.name,
    aws_ssm_document.publication_adapter.name,
    aws_ssm_document.object_readiness.name,
    aws_ssm_document.confluence_publication.name,
    aws_ssm_document.readiness_reconciliation.name,
  ]
}

resource "aws_cloudwatch_log_group" "automation_status" {
  name              = "/aws/events/${var.environment}-automation-status"
  retention_in_days = local.operational_log_retention_days

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_event_rule" "automation_status" {
  name        = "${var.environment}-automation-status"
  description = "Retain terminal status and correlation identifiers for managed SSM Automations without source content or credentials."

  event_pattern = jsonencode({
    source      = ["aws.ssm"]
    detail-type = ["EC2 Automation Execution Status-change Notification"]
    detail = {
      Definition = local.automation_document_names
      Status     = ["Failed", "TimedOut", "Canceled"]
    }
  })

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_event_target" "automation_status" {
  rule      = aws_cloudwatch_event_rule.automation_status.name
  target_id = "SanitizedAutomationStatus"
  arn       = aws_cloudwatch_log_group.automation_status.arn

  input_transformer {
    input_paths = {
      account      = "$.account"
      document     = "$.detail.Definition"
      execution_id = "$.detail.ExecutionId"
      region       = "$.region"
      status       = "$.detail.Status"
      time         = "$.time"
    }
    input_template = <<-JSON
      {"account":<account>,"document":<document>,"executionId":<execution_id>,"region":<region>,"status":<status>,"time":<time>}
    JSON
  }

  depends_on = [aws_cloudwatch_log_resource_policy.native_s3_events]
}

resource "aws_cloudwatch_log_metric_filter" "automation_failures" {
  name           = "terminal-automation-failures"
  log_group_name = aws_cloudwatch_log_group.automation_status.name
  pattern        = "{ $.status = \"Failed\" || $.status = \"TimedOut\" || $.status = \"Canceled\" }"

  metric_transformation {
    name      = "TerminalExecutions"
    namespace = "${var.project_name}/Automation"
    value     = "1"
    dimensions = {
      DocumentName = "$.document"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "automation_failures" {
  for_each = toset(local.automation_document_names)

  alarm_name          = "${var.environment}-${each.value}-terminal-execution"
  alarm_description   = "SSM Automation ${each.value} failed, timed out, or was cancelled; use the execution ID in the sanitized status log and reconcile only its object."
  namespace           = "${var.project_name}/Automation"
  metric_name         = "TerminalExecutions"
  dimensions          = { DocumentName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_metric_alarm" "readiness_target_failed_invocations" {
  for_each = {
    hint      = aws_cloudwatch_event_rule.readiness_hint.name
    scheduled = aws_cloudwatch_event_rule.scheduled_readiness_reconciliation.name
  }

  alarm_name          = "${var.environment}-${each.key}-readiness-target-failed-invocations"
  alarm_description   = "EventBridge permanently failed to start readiness reconciliation; inspect the readiness DLQ and independently reconcile the affected object or run a scan."
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  dimensions          = { RuleName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_metric_alarm" "readiness_dlq_messages" {
  alarm_name          = "${var.environment}-readiness-dlq-messages"
  alarm_description   = "Readiness target delivery exhausted retries; preserve each envelope until its object has been independently reconciled."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.readiness_reconciliation_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_metric_alarm" "transcription_dlq_messages" {
  alarm_name          = "${var.environment}-transcription-dlq-messages"
  alarm_description   = "Transcription target delivery exhausted retries; preserve each envelope until its object has been independently reconciled."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.transcription_event_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Responsibility = "OperationalObservability" }
}

resource "aws_cloudwatch_dashboard" "operations" {
  dashboard_name = "${var.environment}-${var.project_name}-operations"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 4,
        properties = {
          markdown = "# Media publication operations\nPrompt reconciliation runs every ${var.readiness_reconciliation_interval_minutes} minutes. Investigate unpublished objects older than ${local.stale_publication_minutes} minutes and transcription executions running longer than ${local.stuck_transcription_minutes} minutes. Alarms intentionally have no notification action so deployments can bind their owned routing policy."
        }
      },
      {
        type = "alarm", x = 0, y = 4, width = 24, height = 6,
        properties = {
          title = "Actionable delivery and execution alarms"
          alarms = concat(
            [for alarm in aws_cloudwatch_metric_alarm.automation_failures : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.readiness_target_failed_invocations : alarm.arn],
            [aws_cloudwatch_metric_alarm.transcription_target_failed_invocations.arn,
              aws_cloudwatch_metric_alarm.transcription_target_dlq_failures.arn,
              aws_cloudwatch_metric_alarm.transcription_dlq_messages.arn,
            aws_cloudwatch_metric_alarm.readiness_dlq_messages.arn]
          )
        }
      },
      {
        type = "log", x = 0, y = 10, width = 24, height = 6,
        properties = {
          region = var.aws_region
          title  = "Recent failed, timed out, or cancelled Automations"
          query  = "SOURCE '${aws_cloudwatch_log_group.automation_status.name}' | fields @timestamp, document, status, executionId | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
