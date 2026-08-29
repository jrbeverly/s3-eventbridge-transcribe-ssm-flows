output "aws_region" {
  description = "AWS region configured for this root."
  value       = var.aws_region
}

output "environment" {
  description = "Environment name configured for this root."
  value       = var.environment
}

output "operational_tags" {
  description = "Tags applied by default to AWS resources that support tagging."
  value       = local.common_tags
}

output "source_bucket_name" {
  description = "Generated physical name of the bucket that receives source media."
  value       = aws_s3_bucket.source.id
}

output "source_bucket_arn" {
  description = "ARN of the source-media bucket for independently scoped access policies."
  value       = aws_s3_bucket.source.arn
}

output "publication_adapter" {
  description = "External publication adapter binding. The target is interpreted according to the adapter type."
  value = {
    adapter_type = local.publication_adapter_type
    target       = aws_s3_bucket.publication_adapter.id
  }
}

output "publication_adapter_bucket_arn" {
  description = "ARN backing the publication adapter while the s3 adapter is bound, for independently scoped access policies."
  value       = aws_s3_bucket.publication_adapter.arn
}

output "publication_adapter_automation_document_name" {
  description = "Name of the independently invokable S3 publication adapter Automation document."
  value       = aws_ssm_document.publication_adapter.name
}

output "publication_adapter_automation_role_arn" {
  description = "IAM role assumed by the S3 publication adapter Automation document."
  value       = aws_iam_role.publication_adapter.arn
}

output "object_readiness_automation_document_name" {
  description = "Name of the independently invokable source-object readiness Automation document."
  value       = aws_ssm_document.object_readiness.name
}

output "object_readiness_automation_role_arn" {
  description = "IAM role assumed by the source-object readiness Automation document."
  value       = aws_iam_role.object_readiness.arn
}

output "confluence_publication_automation_document_name" {
  description = "Name of the independently invokable idempotent Confluence publication Automation document."
  value       = aws_ssm_document.confluence_publication.name
}

output "confluence_publication_automation_role_arn" {
  description = "IAM role assumed by the Confluence publication Automation document."
  value       = aws_iam_role.confluence_publication.arn
}

output "readiness_reconciliation" {
  description = "Prompt and scheduled readiness-gated publication entry points and fallback interval."
  value = {
    automation_document_name = aws_ssm_document.readiness_reconciliation.name
    event_rule_name          = aws_cloudwatch_event_rule.readiness_hint.name
    schedule_rule_name       = aws_cloudwatch_event_rule.scheduled_readiness_reconciliation.name
    interval_minutes         = var.readiness_reconciliation_interval_minutes
    dlq_url                  = aws_sqs_queue.readiness_reconciliation_dlq.url
  }
}

output "discovery_parameter_names" {
  description = "SSM Parameter Store paths through which runtime consumers resolve these resources."
  value = {
    publication_adapter_type = aws_ssm_parameter.publication_adapter_type.name
    publication_target       = aws_ssm_parameter.publication_target.name
    source_bucket_name       = aws_ssm_parameter.source_bucket_name.name
  }
}

output "transcription_automation_document_name" {
  description = "Name of the independently invokable S3 transcription Automation document."
  value       = aws_ssm_document.transcription.name
}

output "transcription_automation_role_arn" {
  description = "IAM role assumed by the S3 transcription Automation document."
  value       = aws_iam_role.transcription_automation.arn
}

output "transcription_eventbridge_role_arn" {
  description = "Dedicated role used by EventBridge only to start the transcription Automation and pass its execution role."
  value       = aws_iam_role.eventbridge_transcription.arn
}

output "transcription_event_dlq_url" {
  description = "SQS queue retaining eligible source events that EventBridge could not deliver to the transcription Automation."
  value       = aws_sqs_queue.transcription_event_dlq.url
}

output "transcription_target_alarm_names" {
  description = "CloudWatch alarms for permanent target-delivery failures and failures to write those events to the DLQ."
  value = [
    aws_cloudwatch_metric_alarm.transcription_target_failed_invocations.alarm_name,
    aws_cloudwatch_metric_alarm.transcription_target_dlq_failures.alarm_name,
  ]
}

output "native_s3_event_observation_log_group_name" {
  description = "Temporary CloudWatch log group retaining native source-bucket Object Created events for 14 days."
  value       = aws_cloudwatch_log_group.native_s3_events.name
}

output "source_mp4_event_verification_log_group_name" {
  description = "CloudWatch log group receiving source MP4 events for automated event-flow verification."
  value       = aws_cloudwatch_log_group.source_mp4_events.name
}

output "object_probe_automation_document_name" {
  description = "Name of the independently invokable native S3 object probe Automation document."
  value       = aws_ssm_document.object_probe.name
}

output "object_probe_automation_role_arn" {
  description = "IAM role assumed by the native S3 object probe Automation document."
  value       = aws_iam_role.object_probe_automation.arn
}

output "object_probe_eventbridge_role_arn" {
  description = "Dedicated role used by EventBridge only to start the object probe and pass its execution role."
  value       = aws_iam_role.eventbridge_object_probe.arn
}

output "object_probe_event_dlq_url" {
  description = "SQS queue retaining eligible events that EventBridge could not deliver to the object probe Automation."
  value       = aws_sqs_queue.object_probe_event_dlq.url
}

output "object_probe_target_alarm_names" {
  description = "CloudWatch alarms for permanent object-probe target failures and failures to retain them in the DLQ."
  value = [
    aws_cloudwatch_metric_alarm.object_probe_target_failed_invocations.alarm_name,
    aws_cloudwatch_metric_alarm.object_probe_target_dlq_failures.alarm_name,
  ]
}

output "operational_observability" {
  description = "Durable dashboard, sanitized Automation status log, alarm names, and eventual-consistency investigation bounds."
  value = {
    automation_status_log_group_name = aws_cloudwatch_log_group.automation_status.name
    dashboard_name                   = aws_cloudwatch_dashboard.operations.dashboard_name
    stale_publication_minutes        = local.stale_publication_minutes
    stuck_transcription_minutes      = local.stuck_transcription_minutes
    alarm_names = concat(
      [for alarm in aws_cloudwatch_metric_alarm.automation_failures : alarm.alarm_name],
      [for alarm in aws_cloudwatch_metric_alarm.readiness_target_failed_invocations : alarm.alarm_name],
      [aws_cloudwatch_metric_alarm.object_probe_target_failed_invocations.alarm_name,
        aws_cloudwatch_metric_alarm.object_probe_target_dlq_failures.alarm_name,
      ],
      [aws_cloudwatch_metric_alarm.transcription_target_failed_invocations.alarm_name,
        aws_cloudwatch_metric_alarm.transcription_target_dlq_failures.alarm_name,
        aws_cloudwatch_metric_alarm.transcription_dlq_messages.alarm_name,
      aws_cloudwatch_metric_alarm.readiness_dlq_messages.alarm_name]
    )
  }
}
