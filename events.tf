resource "aws_s3_bucket_notification" "source" {
  bucket      = aws_s3_bucket.source.id
  eventbridge = true
}

resource "aws_cloudwatch_log_group" "native_s3_events" {
  name              = "/aws/events/${var.environment}-native-s3-object-created"
  retention_in_days = 14

  tags = {
    Responsibility = "TemporaryEventObservation"
  }
}

resource "aws_cloudwatch_log_group" "source_mp4_events" {
  name              = "/aws/events/${var.environment}-source-mp4-created"
  retention_in_days = 14

  tags = {
    Responsibility = "EventFlowVerification"
  }
}

resource "aws_cloudwatch_log_resource_policy" "native_s3_events" {
  policy_name = "${var.environment}-native-s3-event-observation"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventBridgeWrite"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.native_s3_events.arn}:*",
          "${aws_cloudwatch_log_group.source_mp4_events.arn}:*",
          "${aws_cloudwatch_log_group.automation_status.arn}:*",
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_event_rule" "native_s3_object_created" {
  name        = "${var.environment}-native-s3-object-created"
  description = "Temporarily retain native source-bucket Object Created events for schema observation."

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.source.id]
      }
    }
  })

  tags = {
    Responsibility = "TemporaryEventObservation"
  }
}

resource "aws_cloudwatch_event_rule" "source_mp4_created" {
  name        = "${var.environment}-source-mp4-created"
  description = "Match MP4 creation in the source bucket without constraining user-selected key prefixes."

  event_pattern = templatefile("${path.module}/event-patterns/source-mp4-created.json.tftpl", {
    source_bucket_name = jsonencode(aws_s3_bucket.source.id)
  })

  tags = {
    Responsibility = "SourceMediaTranscription"
  }
}

locals {
  transcription_automation_definition_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.transcription.name}:$DEFAULT"
  object_probe_automation_definition_arn  = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.object_probe.name}:$DEFAULT"
}

resource "aws_iam_role" "eventbridge_object_probe" {
  name = "${var.environment}-eventbridge-object-probe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.source_mp4_created.arn
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_object_probe" {
  name = "start-object-probe-automation"
  role = aws_iam_role.eventbridge_object_probe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          local.object_probe_automation_definition_arn,
          replace(replace(local.object_probe_automation_definition_arn, "automation-definition/", "document/"), ":$DEFAULT", ""),
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.object_probe_automation.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_sqs_queue" "object_probe_event_dlq" {
  name                      = "${var.environment}-object-probe-event-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Responsibility = "SourceObjectInspection"
  }
}

resource "aws_sqs_queue_policy" "object_probe_event_dlq" {
  queue_url = aws_sqs_queue.object_probe_event_dlq.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EventBridgeSendFailedInvocation"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.object_probe_event_dlq.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.source_mp4_created.arn
        }
      }
    }]
  })
}

resource "aws_iam_role" "eventbridge_transcription" {
  name = "${var.environment}-eventbridge-transcription"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.source_mp4_created.arn
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_transcription" {
  name = "start-transcription-automation"
  role = aws_iam_role.eventbridge_transcription.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          local.transcription_automation_definition_arn,
          replace(replace(local.transcription_automation_definition_arn, "automation-definition/", "document/"), ":$DEFAULT", ""),
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.transcription_automation.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_sqs_queue" "transcription_event_dlq" {
  name                      = "${var.environment}-transcription-event-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Responsibility = "SourceMediaTranscription"
  }
}

resource "aws_sqs_queue_policy" "transcription_event_dlq" {
  queue_url = aws_sqs_queue.transcription_event_dlq.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventBridgeSendFailedInvocation"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.transcription_event_dlq.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.source_mp4_created.arn
          }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_event_target" "native_s3_events" {
  rule      = aws_cloudwatch_event_rule.native_s3_object_created.name
  target_id = "CloudWatchLogs"
  arn       = aws_cloudwatch_log_group.native_s3_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.native_s3_events]
}

resource "aws_cloudwatch_event_target" "source_mp4_events" {
  rule      = aws_cloudwatch_event_rule.source_mp4_created.name
  target_id = "CloudWatchLogs"
  arn       = aws_cloudwatch_log_group.source_mp4_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.native_s3_events]
}

resource "aws_cloudwatch_event_target" "transcription_automation" {
  rule      = aws_cloudwatch_event_rule.source_mp4_created.name
  target_id = "TranscriptionAutomation"
  arn       = local.transcription_automation_definition_arn
  role_arn  = aws_iam_role.eventbridge_transcription.arn

  input_transformer {
    input_paths = {
      bucket   = "$.detail.bucket.name"
      event_id = "$.id"
      key      = "$.detail.object.key"
    }
    input_template = <<-JSON
      {"BucketName":[<bucket>],"ObjectKey":[<key>],"SourceEventId":[<event_id>]}
    JSON
  }

  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }

  dead_letter_config {
    arn = aws_sqs_queue.transcription_event_dlq.arn
  }

  depends_on = [aws_sqs_queue_policy.transcription_event_dlq]
}

resource "aws_cloudwatch_event_target" "object_probe_automation" {
  rule      = aws_cloudwatch_event_rule.source_mp4_created.name
  target_id = "ObjectProbeAutomation"
  arn       = local.object_probe_automation_definition_arn
  role_arn  = aws_iam_role.eventbridge_object_probe.arn

  input_transformer {
    input_paths = {
      bucket     = "$.detail.bucket.name"
      key        = "$.detail.object.key"
      version_id = "$.detail.object.version-id"
    }
    input_template = <<-JSON
      {"BucketName":[<bucket>],"ObjectKey":[<key>],"VersionId":[<version_id>]}
    JSON
  }

  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }

  dead_letter_config {
    arn = aws_sqs_queue.object_probe_event_dlq.arn
  }

  depends_on = [aws_sqs_queue_policy.object_probe_event_dlq]
}

resource "aws_cloudwatch_metric_alarm" "object_probe_target_failed_invocations" {
  alarm_name          = "${var.environment}-object-probe-target-failed-invocations"
  alarm_description   = "EventBridge permanently failed to start the object probe Automation; inspect its target DLQ."
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  dimensions          = { RuleName = aws_cloudwatch_event_rule.source_mp4_created.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Responsibility = "SourceObjectInspection"
  }
}

resource "aws_cloudwatch_metric_alarm" "object_probe_target_dlq_failures" {
  alarm_name          = "${var.environment}-object-probe-target-dlq-failures"
  alarm_description   = "EventBridge could not place a failed object probe invocation onto its target DLQ."
  namespace           = "AWS/Events"
  metric_name         = "InvocationsFailedToBeSentToDlq"
  dimensions          = { RuleName = aws_cloudwatch_event_rule.source_mp4_created.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Responsibility = "SourceObjectInspection"
  }
}

resource "aws_cloudwatch_metric_alarm" "transcription_target_failed_invocations" {
  alarm_name          = "${var.environment}-transcription-target-failed-invocations"
  alarm_description   = "EventBridge permanently failed to start the transcription Automation; inspect its target DLQ."
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  dimensions          = { RuleName = aws_cloudwatch_event_rule.source_mp4_created.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Responsibility = "SourceMediaTranscription"
  }
}

resource "aws_cloudwatch_metric_alarm" "transcription_target_dlq_failures" {
  alarm_name          = "${var.environment}-transcription-target-dlq-failures"
  alarm_description   = "EventBridge could not place a failed transcription invocation onto its target DLQ."
  namespace           = "AWS/Events"
  metric_name         = "InvocationsFailedToBeSentToDlq"
  dimensions          = { RuleName = aws_cloudwatch_event_rule.source_mp4_created.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Responsibility = "SourceMediaTranscription"
  }
}
