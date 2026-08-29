locals {
  readiness_reconciliation_definition_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.readiness_reconciliation.name}:$DEFAULT"
  confluence_publication_definition_arn   = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.confluence_publication.name}:$DEFAULT"

  dispatch_readiness_reconciliation_script = <<-PYTHON
    import boto3

    def dispatch(events, context):
        bucket = events["SourceBucketName"]
        changed_key = events.get("ChangedObjectKey", "")
        ssm = boto3.client("ssm")

        if changed_key.lower().endswith(".mp4"):
            keys = [changed_key]
            list_request_count = 0
        elif changed_key.lower().endswith(".transcription.vtt"):
            s3 = boto3.client("s3")
            suffix = ".transcription.vtt"
            source_prefix = changed_key[:-len(suffix)]
            expected_key = (source_prefix + ".mp4").lower()
            page = s3.list_objects_v2(Bucket=bucket, Prefix=source_prefix, MaxKeys=1000)
            list_request_count = 1
            keys = [item["Key"] for item in page.get("Contents", [])
                    if item["Key"].lower() == expected_key]
        elif changed_key:
            keys = []
            list_request_count = 0
        else:
            s3 = boto3.client("s3")
            keys = []
            list_request_count = 0
            continuation_token = None
            while True:
                request = {"Bucket": bucket, "MaxKeys": 1000}
                if continuation_token:
                    request["ContinuationToken"] = continuation_token
                page = s3.list_objects_v2(**request)
                list_request_count += 1
                keys.extend(item["Key"] for item in page.get("Contents", [])
                            if item["Key"].lower().endswith(".mp4"))
                if not page.get("IsTruncated"):
                    break
                continuation_token = page["NextContinuationToken"]

        execution_ids = []
        for key in keys:
            response = ssm.start_automation_execution(
                DocumentName=events["ConfluencePublicationDocumentName"],
                Parameters={
                    "SourceBucketName": [bucket],
                    "SourceObjectKey": [key],
                },
            )
            execution_ids.append(response["AutomationExecutionId"])

        return {
            "CandidateCount": len(keys),
            "ListRequestCount": list_request_count,
            "ExecutionIds": execution_ids,
        }
  PYTHON
}

resource "aws_iam_role" "readiness_reconciliation" {
  name = "${var.environment}-readiness-reconciliation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "readiness_reconciliation" {
  name = "discover-and-publish-ready-objects"
  role = aws_iam_role.readiness_reconciliation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.source.arn
      },
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          local.confluence_publication_definition_arn,
          replace(replace(local.confluence_publication_definition_arn, "automation-definition/", "document/"), ":$DEFAULT", ""),
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.confluence_publication.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_ssm_document" "readiness_reconciliation" {
  name            = "${var.environment}-trigger-readiness-reconciliation"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Turn one S3 change hint or a paginated source-bucket scan into independently retryable Confluence publication executions, each of which evaluates current readiness before publishing."
    assumeRole    = aws_iam_role.readiness_reconciliation.arn
    parameters = {
      SourceBucketName = {
        type           = "String"
        default        = aws_s3_bucket.source.id
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      ChangedObjectKey = {
        type        = "String"
        default     = ""
        description = "Literal changed MP4 or transcription VTT key. Empty means scheduled discovery."
      }
    }
    outputs = [
      "dispatchReadiness.CandidateCount",
      "dispatchReadiness.ListRequestCount",
      "dispatchReadiness.ExecutionIds",
    ]
    mainSteps = [{
      name           = "dispatchReadiness"
      action         = "aws:executeScript"
      timeoutSeconds = 600
      maxAttempts    = 3
      onFailure      = "Abort"
      isEnd          = true
      inputs = {
        Runtime = "python3.11"
        Handler = "dispatch"
        Script  = local.dispatch_readiness_reconciliation_script
        InputPayload = {
          ChangedObjectKey                  = "{{ ChangedObjectKey }}"
          ConfluencePublicationDocumentName = aws_ssm_document.confluence_publication.name
          SourceBucketName                  = "{{ SourceBucketName }}"
        }
      }
      outputs = [
        {
          Name     = "CandidateCount"
          Selector = "$.Payload.CandidateCount"
          Type     = "Integer"
        },
        {
          Name     = "ListRequestCount"
          Selector = "$.Payload.ListRequestCount"
          Type     = "Integer"
        },
        {
          Name     = "ExecutionIds"
          Selector = "$.Payload.ExecutionIds"
          Type     = "StringList"
        },
      ]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "readiness_hint" {
  name        = "${var.environment}-readiness-hint"
  description = "Treat source MP4, transcription VTT, and publication annotation changes as hints to reevaluate current object readiness."

  event_pattern = templatefile("${path.module}/event-patterns/readiness-hint.json.tftpl", {
    source_bucket_name = jsonencode(aws_s3_bucket.source.id)
  })

  tags = {
    Responsibility = "ConfluenceReadiness"
  }
}

resource "aws_cloudwatch_event_rule" "scheduled_readiness_reconciliation" {
  name                = "${var.environment}-scheduled-readiness-reconciliation"
  description         = "Discover source MP4s and reevaluate readiness after hints are delayed or missed."
  schedule_expression = "rate(${var.readiness_reconciliation_interval_minutes} minutes)"

  tags = {
    Responsibility = "ConfluenceReadiness"
  }
}

resource "aws_iam_role" "eventbridge_readiness_reconciliation" {
  name = "${var.environment}-eventbridge-readiness-reconciliation"

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
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.environment}-*readiness*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_readiness_reconciliation" {
  name = "start-readiness-reconciliation"
  role = aws_iam_role.eventbridge_readiness_reconciliation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          local.readiness_reconciliation_definition_arn,
          replace(replace(local.readiness_reconciliation_definition_arn, "automation-definition/", "document/"), ":$DEFAULT", ""),
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.readiness_reconciliation.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_sqs_queue" "readiness_reconciliation_dlq" {
  name                      = "${var.environment}-readiness-reconciliation-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Responsibility = "ConfluenceReadiness"
  }
}

resource "aws_sqs_queue_policy" "readiness_reconciliation_dlq" {
  queue_url = aws_sqs_queue.readiness_reconciliation_dlq.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBridgeSendFailedReadinessInvocation"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.readiness_reconciliation_dlq.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.environment}-*readiness*"
        }
      }
    }]
  })
}

resource "aws_cloudwatch_event_target" "readiness_hint" {
  rule      = aws_cloudwatch_event_rule.readiness_hint.name
  target_id = "ReadinessReconciliation"
  arn       = local.readiness_reconciliation_definition_arn
  role_arn  = aws_iam_role.eventbridge_readiness_reconciliation.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<-JSON
      {"SourceBucketName":[<bucket>],"ChangedObjectKey":[<key>]}
    JSON
  }

  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }

  dead_letter_config {
    arn = aws_sqs_queue.readiness_reconciliation_dlq.arn
  }

  depends_on = [aws_sqs_queue_policy.readiness_reconciliation_dlq]
}

resource "aws_cloudwatch_event_target" "scheduled_readiness_reconciliation" {
  rule      = aws_cloudwatch_event_rule.scheduled_readiness_reconciliation.name
  target_id = "ScheduledReadinessReconciliation"
  arn       = local.readiness_reconciliation_definition_arn
  role_arn  = aws_iam_role.eventbridge_readiness_reconciliation.arn
  input = jsonencode({
    SourceBucketName = [aws_s3_bucket.source.id]
  })

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.readiness_reconciliation_dlq.arn
  }

  depends_on = [aws_sqs_queue_policy.readiness_reconciliation_dlq]
}
