locals {
  derive_s3_publication_identity_script = <<-PYTHON
    from urllib.parse import quote

    def derive(events, context):
        bucket = events["DestinationBucketName"]
        key = events["SourceObjectKey"]
        version_id = events["SourceVersionId"]
        return {
            "CopySource": quote(
                events["SourceBucketName"] + "/" + key,
                safe="/",
            ) + "?versionId=" + quote(version_id, safe=""),
            "DestinationId": key,
            "DestinationKey": key,
            "MediaUrl": (
                "https://"
                + bucket
                + ".s3."
                + events["Region"]
                + "."
                + events["DnsSuffix"]
                + "/"
                + quote(key, safe="/")
            ),
        }
  PYTHON

  finalize_s3_publication_result_script = <<-PYTHON
    def finalize(events, context):
        return {
            "ConcurrencyToken": events["DestinationVersionId"],
            "DestinationDetails": {
                "BucketName": events["DestinationBucketName"],
                "ETag": events["DestinationETag"],
                "ObjectKey": events["DestinationId"],
                "VersionId": events["DestinationVersionId"],
            },
            "DestinationId": events["DestinationId"],
            "DestinationType": "s3",
            "MediaUrl": events["MediaUrl"],
        }
  PYTHON

  write_publication_annotations_script = join("", [local.s3_annotation_model_prelude, <<-PYTHON
    import boto3
    from botocore.exceptions import ClientError

    def write(events, context):
        s3 = boto3.client("s3")
        common = {
            "Bucket": events["SourceBucketName"],
            "Key": events["SourceObjectKey"],
            "VersionId": events["SourceVersionId"],
            "ObjectIfMatch": events["SourceETag"],
        }
        annotations = {
            "publication.destination": events["DestinationType"],
            "publication.url": events["MediaUrl"],
            "publication.id": events["DestinationId"],
            "publication.concurrency-token": events["ConcurrencyToken"],
        }
        changed = []
        for name, payload in annotations.items():
            try:
                existing = s3.get_object_annotation(
                    Bucket=common["Bucket"],
                    Key=common["Key"],
                    VersionId=common["VersionId"],
                    AnnotationName=name,
                )["AnnotationPayload"].read().decode("utf-8")
            except ClientError as error:
                if error.response["Error"]["Code"] not in {
                    "404", "NoSuchAnnotation", "NoSuchKey"
                }:
                    raise
                existing = None
            if existing == payload:
                continue
            s3.put_object_annotation(
                **common,
                AnnotationName=name,
                AnnotationPayload=payload.encode("utf-8"),
            )
            changed.append(name)
        return {"ChangedAnnotationNames": changed}
  PYTHON
  ])
}

resource "aws_iam_role" "publication_adapter" {
  name = "${var.environment}-s3-publication-adapter"

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

resource "aws_iam_role_policy" "publication_adapter" {
  name = "publish-source-media-to-s3"
  role = aws_iam_role.publication_adapter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectAnnotation",
          "s3:GetObjectVersionAnnotation",
          "s3:GetObjectVersion",
          "s3:PutObjectAnnotation",
          "s3:PutObjectVersionAnnotation",
        ]
        Resource = "${aws_s3_bucket.source.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.publication_adapter.arn}/*"
      },
    ]
  })
}

resource "aws_ssm_document" "publication_adapter" {
  name            = "${var.environment}-publish-s3-object"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Reconcile one source MP4 version with the S3 publication destination, retain the literal source key, and return the destination-independent publication result."
    assumeRole    = aws_iam_role.publication_adapter.arn
    parameters = {
      SourceBucketName = {
        type           = "String"
        description    = "S3 bucket containing the source MP4. The Automation role is scoped to the Terraform-managed source bucket."
        default        = aws_s3_bucket.source.id
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      SourceObjectKey = {
        type           = "String"
        description    = "Exact, literal key of the source MP4; the destination preserves this key."
        allowedPattern = "^.+\\.[mM][pP]4$"
      }
      SourceVersionId = {
        type           = "String"
        description    = "Exact source version to publish. When omitted, the current version is resolved once before publication."
        default        = ""
        allowedPattern = "^$|^[A-Za-z0-9._~+/=-]+$"
      }
    }
    variables = {
      ResolvedSourceVersionId = {
        type    = "String"
        default = "unresolved"
      }
    }
    outputs = [
      "finalizePublicationResult.DestinationType",
      "finalizePublicationResult.MediaUrl",
      "finalizePublicationResult.DestinationId",
      "finalizePublicationResult.ConcurrencyToken",
      "finalizePublicationResult.DestinationDetails",
    ]
    mainSteps = [
      {
        name   = "chooseSourceVersion"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              Variable     = "{{ SourceVersionId }}"
              StringEquals = ""
              NextStep     = "probeCurrentSource"
            },
          ]
          Default = "probeRequestedSource"
        }
      },
      {
        name           = "probeCurrentSource"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ SourceBucketName }}"
          Key     = "{{ SourceObjectKey }}"
        }
        outputs = [
          {
            Name     = "VersionId"
            Selector = "$.VersionId"
            Type     = "String"
          },
        ]
      },
      {
        name     = "rememberCurrentSourceVersion"
        action   = "aws:updateVariable"
        nextStep = "probeResolvedSource"
        inputs = {
          Name  = "variable:ResolvedSourceVersionId"
          Value = "{{ probeCurrentSource.VersionId }}"
        }
      },
      {
        name           = "probeRequestedSource"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        inputs = {
          Service   = "s3"
          Api       = "HeadObject"
          Bucket    = "{{ SourceBucketName }}"
          Key       = "{{ SourceObjectKey }}"
          VersionId = "{{ SourceVersionId }}"
        }
        outputs = [
          {
            Name     = "VersionId"
            Selector = "$.VersionId"
            Type     = "String"
          },
        ]
      },
      {
        name     = "rememberRequestedSourceVersion"
        action   = "aws:updateVariable"
        nextStep = "probeResolvedSource"
        inputs = {
          Name  = "variable:ResolvedSourceVersionId"
          Value = "{{ probeRequestedSource.VersionId }}"
        }
      },
      {
        name           = "probeResolvedSource"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        inputs = {
          Service   = "s3"
          Api       = "HeadObject"
          Bucket    = "{{ SourceBucketName }}"
          Key       = "{{ SourceObjectKey }}"
          VersionId = "{{ variable:ResolvedSourceVersionId }}"
        }
        outputs = [
          {
            Name     = "ContentLength"
            Selector = "$.ContentLength"
            Type     = "Integer"
          },
          {
            Name     = "ETag"
            Selector = "$.ETag"
            Type     = "String"
          },
        ]
      },
      {
        name           = "derivePublicationIdentity"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "derive"
          Script  = local.derive_s3_publication_identity_script
          InputPayload = {
            DestinationBucketName = aws_s3_bucket.publication_adapter.id
            DnsSuffix             = data.aws_partition.current.dns_suffix
            Region                = var.aws_region
            SourceBucketName      = "{{ SourceBucketName }}"
            SourceObjectKey       = "{{ SourceObjectKey }}"
            SourceVersionId       = "{{ variable:ResolvedSourceVersionId }}"
          }
        }
        outputs = [
          {
            Name     = "CopySource"
            Selector = "$.Payload.CopySource"
            Type     = "String"
          },
          {
            Name     = "DestinationId"
            Selector = "$.Payload.DestinationId"
            Type     = "String"
          },
          {
            Name     = "DestinationKey"
            Selector = "$.Payload.DestinationKey"
            Type     = "String"
          },
          {
            Name     = "MediaUrl"
            Selector = "$.Payload.MediaUrl"
            Type     = "String"
          },
        ]
      },
      {
        name           = "probeDestination"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:copyToDestination"
        nextStep       = "compareDestination"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = aws_s3_bucket.publication_adapter.id
          Key     = "{{ derivePublicationIdentity.DestinationKey }}"
        }
        outputs = [
          {
            Name     = "ContentLength"
            Selector = "$.ContentLength"
            Type     = "Integer"
          },
          {
            Name     = "ETag"
            Selector = "$.ETag"
            Type     = "String"
          },
        ]
      },
      {
        name   = "compareDestination"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              And = [
                {
                  Variable     = "{{ probeDestination.ETag }}"
                  StringEquals = "{{ probeResolvedSource.ETag }}"
                },
                {
                  Variable      = "{{ probeDestination.ContentLength }}"
                  NumericEquals = "{{ probeResolvedSource.ContentLength }}"
                },
              ]
              NextStep = "probePublishedObject"
            },
          ]
          Default = "copyToDestination"
        }
      },
      {
        name           = "copyToDestination"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 1
        onFailure      = "Abort"
        nextStep       = "probePublishedObject"
        inputs = {
          Service              = "s3"
          Api                  = "CopyObject"
          Bucket               = aws_s3_bucket.publication_adapter.id
          Key                  = "{{ derivePublicationIdentity.DestinationKey }}"
          CopySource           = "{{ derivePublicationIdentity.CopySource }}"
          MetadataDirective    = "COPY"
          ServerSideEncryption = "AES256"
          TaggingDirective     = "COPY"
        }
      },
      {
        name           = "probePublishedObject"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = aws_s3_bucket.publication_adapter.id
          Key     = "{{ derivePublicationIdentity.DestinationKey }}"
        }
        outputs = [
          {
            Name     = "ETag"
            Selector = "$.ETag"
            Type     = "String"
          },
          {
            Name     = "VersionId"
            Selector = "$.VersionId"
            Type     = "String"
          },
        ]
      },
      {
        name           = "finalizePublicationResult"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "finalize"
          Script  = local.finalize_s3_publication_result_script
          InputPayload = {
            DestinationBucketName = aws_s3_bucket.publication_adapter.id
            DestinationETag       = "{{ probePublishedObject.ETag }}"
            DestinationId         = "{{ derivePublicationIdentity.DestinationId }}"
            DestinationVersionId  = "{{ probePublishedObject.VersionId }}"
            MediaUrl              = "{{ derivePublicationIdentity.MediaUrl }}"
          }
        }
        outputs = [
          {
            Name     = "ConcurrencyToken"
            Selector = "$.Payload.ConcurrencyToken"
            Type     = "String"
          },
          {
            Name     = "DestinationDetails"
            Selector = "$.Payload.DestinationDetails"
            Type     = "StringMap"
          },
          {
            Name     = "DestinationId"
            Selector = "$.Payload.DestinationId"
            Type     = "String"
          },
          {
            Name     = "DestinationType"
            Selector = "$.Payload.DestinationType"
            Type     = "String"
          },
          {
            Name     = "MediaUrl"
            Selector = "$.Payload.MediaUrl"
            Type     = "String"
          },
        ]
      },
      {
        name           = "writePublicationAnnotations"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 3
        onFailure      = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "write"
          Script  = local.write_publication_annotations_script
          InputPayload = {
            ConcurrencyToken = "{{ finalizePublicationResult.ConcurrencyToken }}"
            DestinationId    = "{{ finalizePublicationResult.DestinationId }}"
            DestinationType  = "{{ finalizePublicationResult.DestinationType }}"
            MediaUrl         = "{{ finalizePublicationResult.MediaUrl }}"
            SourceBucketName = "{{ SourceBucketName }}"
            SourceETag       = "{{ probeResolvedSource.ETag }}"
            SourceObjectKey  = "{{ SourceObjectKey }}"
            SourceVersionId  = "{{ variable:ResolvedSourceVersionId }}"
          }
        }
      },
    ]
  })
}
