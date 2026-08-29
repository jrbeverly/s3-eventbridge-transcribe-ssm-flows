resource "aws_iam_role" "object_probe_automation" {
  name = "${var.environment}-object-probe-automation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      },
    ]
  })
}

resource "aws_iam_role_policy" "object_probe_automation" {
  name = "inspect-source-object"
  role = aws_iam_role.object_probe_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
        ]
        Resource = "${aws_s3_bucket.source.arn}/*"
      },
    ]
  })
}

resource "aws_ssm_document" "object_probe" {
  name            = "${var.environment}-probe-s3-object"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Inspect one S3 object through native AWS API actions. A supplied version is inspected exactly; otherwise the current object is inspected. Missing objects and inaccessible versions fail the corresponding HeadObject step."
    assumeRole    = aws_iam_role.object_probe_automation.arn
    parameters = {
      BucketName = {
        type           = "String"
        description    = "Bucket containing the object. The Automation role is scoped to the Terraform-managed source bucket."
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      ObjectKey = {
        type           = "String"
        description    = "Exact, literal S3 object key."
        allowedPattern = "^.{1,1024}$"
      }
      VersionId = {
        type           = "String"
        description    = "Optional exact S3 version ID. An empty value inspects the current object."
        default        = ""
        allowedPattern = "^$|^[A-Za-z0-9._~+/=-]+$"
      }
    }
    mainSteps = [
      {
        name     = "selectObjectVersion"
        action   = "aws:branch"
        onCancel = "Abort"
        inputs = {
          Choices = [
            {
              Variable     = "{{ VersionId }}"
              StringEquals = ""
              NextStep     = "inspectCurrentObject"
            },
          ]
          Default = "inspectRequestedVersion"
        }
      },
      {
        name           = "inspectCurrentObject"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "Abort"
        isEnd          = true
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ BucketName }}"
          Key     = "{{ ObjectKey }}"
        }
        outputs = [
          { Name = "ContentLength", Selector = "$.ContentLength", Type = "Integer" },
          { Name = "ContentType", Selector = "$.ContentType", Type = "String" },
          { Name = "ETag", Selector = "$.ETag", Type = "String" },
          { Name = "LastModified", Selector = "$.LastModified", Type = "String" },
          { Name = "VersionId", Selector = "$.VersionId", Type = "String" },
        ]
      },
      {
        name           = "inspectRequestedVersion"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "Abort"
        isEnd          = true
        inputs = {
          Service   = "s3"
          Api       = "HeadObject"
          Bucket    = "{{ BucketName }}"
          Key       = "{{ ObjectKey }}"
          VersionId = "{{ VersionId }}"
        }
        outputs = [
          { Name = "ContentLength", Selector = "$.ContentLength", Type = "Integer" },
          { Name = "ContentType", Selector = "$.ContentType", Type = "String" },
          { Name = "ETag", Selector = "$.ETag", Type = "String" },
          { Name = "LastModified", Selector = "$.LastModified", Type = "String" },
          { Name = "VersionId", Selector = "$.VersionId", Type = "String" },
        ]
      },
    ]
  })

  tags = {
    Responsibility = "SourceObjectInspection"
  }
}
