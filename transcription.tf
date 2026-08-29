data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  derive_transcription_identity_script = <<-PYTHON
    import hashlib

    def derive(events, context):
        bucket = events["BucketName"]
        key = events["ObjectKey"]
        version_id = events["VersionId"]
        digest = hashlib.sha256(
            (bucket + "\0" + key + "\0" + version_id).encode("utf-8")
        ).hexdigest()

        parent, separator, filename = key.rpartition("/")
        stem = filename[:-4] if filename.lower().endswith(".mp4") else filename
        output_prefix = (
            (parent + separator if separator else "")
            + stem
            + ".transcription/"
        )

        return {
            "JobName": "transcribe-" + digest,
            "MediaUri": "s3://" + bucket + "/" + key,
            "OutputPrefix": output_prefix,
        }
  PYTHON

  fail_automation_script = <<-PYTHON
    def fail(events, context):
        raise Exception(events["Message"])
  PYTHON

  derive_transcription_artifact_script = <<-PYTHON
    from urllib.parse import quote, unquote, urlparse

    def materialize(events, context):
        bucket = events["BucketName"]
        key = events["ObjectKey"]
        version_id = events["VersionId"]
        subtitle_uris = events["SubtitleFileUris"]
        if not isinstance(subtitle_uris, list) or len(subtitle_uris) != 1:
            raise ValueError("Amazon Transcribe must return exactly one VTT URI")

        def staging_key(uri, extension):
            parsed = urlparse(uri)
            if parsed.scheme == "s3" and parsed.netloc == bucket:
                return unquote(parsed.path.lstrip("/"))
            if parsed.scheme == "https" and parsed.path.startswith("/" + bucket + "/"):
                return unquote(parsed.path[len(bucket) + 2:])
            raise ValueError(
                "Amazon Transcribe returned an unexpected " + extension + " URI"
            )

        parent, separator, filename = key.rpartition("/")
        stem = filename[:-4]
        artifact_base = (parent + separator if separator else "") + stem
        json_key = artifact_base + ".transcription.json"
        vtt_key = artifact_base + ".transcription.vtt"
        if max(len(json_key.encode("utf-8")), len(vtt_key.encode("utf-8"))) > 1024:
            raise ValueError("A deterministic transcription artifact key exceeds 1,024 bytes")

        tags = {
            "Environment": events["Environment"],
            "ManagedBy": "SSMAutomation",
            "Project": events["ProjectName"],
            "Responsibility": "TranscriptionArtifact",
            "SourceVersionId": version_id,
        }
        tagging = "&".join(
            quote(name, safe="") + "=" + quote(value, safe="")
            for name, value in tags.items()
        )

        json_staging_key = staging_key(events["TranscriptFileUri"], "JSON")
        vtt_staging_key = staging_key(subtitle_uris[0], "VTT")
        return {
            "JsonCopySource": quote(bucket + "/" + json_staging_key, safe="/"),
            "JsonKey": json_key,
            "JsonUri": "s3://" + bucket + "/" + json_key,
            "Tagging": tagging,
            "VttCopySource": quote(bucket + "/" + vtt_staging_key, safe="/"),
            "VttKey": vtt_key,
            "VttUri": "s3://" + bucket + "/" + vtt_key,
        }
  PYTHON
}

resource "aws_iam_role" "transcription_automation" {
  name = "${var.environment}-transcription-automation"

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

resource "aws_iam_role_policy" "transcription_automation" {
  name = "transcribe-source-media"
  role = aws_iam_role.transcription_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:PutObjectTagging",
        ]
        Resource = "${aws_s3_bucket.source.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "transcribe:GetTranscriptionJob",
          "transcribe:StartTranscriptionJob",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_ssm_document" "transcription" {
  name            = "${var.environment}-transcribe-s3-object"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Reconcile one current S3 object with a deterministic Amazon Transcribe job, wait up to four hours, and materialize complete JSON and VTT output at stable source-adjacent keys. API steps retry three times except StartTranscriptionJob, whose ambiguous failure is reconciled by reading the job. Cancellation leaves the service job intact and records its current state so a later execution can reuse it."
    assumeRole    = aws_iam_role.transcription_automation.arn
    parameters = {
      BucketName = {
        type           = "String"
        description    = "S3 bucket containing the current MP4 object. The Automation role is scoped to the Terraform-managed source bucket."
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      ObjectKey = {
        type           = "String"
        description    = "Exact key of the current MP4 object."
        allowedPattern = "^.+\\.[mM][pP]4$"
      }
      LanguageCode = {
        type           = "String"
        description    = "Language code supplied explicitly to Amazon Transcribe."
        default        = "en-US"
        allowedPattern = "^[a-z]{2,3}-[A-Z]{2}$"
      }
      SourceEventId = {
        type           = "String"
        description    = "Native EventBridge event ID used for operator correlation, or a caller-selected token for an independent invocation."
        default        = "manual"
        allowedPattern = "^[A-Za-z0-9][A-Za-z0-9._:/=-]{0,127}$"
      }
    }
    outputs = [
      "deriveTranscriptionIdentity.JobName",
      "deriveTranscriptionArtifacts.JsonUri",
      "deriveTranscriptionArtifacts.VttUri",
    ]
    mainSteps = [
      {
        name           = "probeCurrentObject"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ BucketName }}"
          Key     = "{{ ObjectKey }}"
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
        name           = "deriveTranscriptionIdentity"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "derive"
          Script  = local.derive_transcription_identity_script
          InputPayload = {
            BucketName = "{{ BucketName }}"
            ObjectKey  = "{{ ObjectKey }}"
            VersionId  = "{{ probeCurrentObject.VersionId }}"
          }
        }
        outputs = [
          {
            Name     = "JobName"
            Selector = "$.Payload.JobName"
            Type     = "String"
          },
          {
            Name     = "MediaUri"
            Selector = "$.Payload.MediaUri"
            Type     = "String"
          },
          {
            Name     = "OutputPrefix"
            Selector = "$.Payload.OutputPrefix"
            Type     = "String"
          },
        ]
      },
      {
        name           = "getExistingJob"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:startJob"
        onCancel       = "step:getCancellationState"
        nextStep       = "validateExistingJob"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "MediaUri"
            Selector = "$.TranscriptionJob.Media.MediaFileUri"
            Type     = "String"
          },
          {
            Name     = "LanguageCode"
            Selector = "$.TranscriptionJob.LanguageCode"
            Type     = "String"
          },
          {
            Name     = "MediaFormat"
            Selector = "$.TranscriptionJob.MediaFormat"
            Type     = "String"
          },
          {
            Name     = "SubtitleFormats"
            Selector = "$.TranscriptionJob.Subtitles.Formats"
            Type     = "StringList"
          },
          {
            Name     = "SubtitleStartIndex"
            Selector = "$.TranscriptionJob.Subtitles.OutputStartIndex"
            Type     = "Integer"
          },
        ]
      },
      {
        name           = "startJob"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 1
        isCritical     = false
        onFailure      = "step:getJobAfterStartFailure"
        onCancel       = "step:getCancellationState"
        nextStep       = "waitForTerminalState"
        inputs = {
          Service              = "transcribe"
          Api                  = "StartTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
          LanguageCode         = "{{ LanguageCode }}"
          MediaFormat          = "mp4"
          Media = {
            MediaFileUri = "{{ deriveTranscriptionIdentity.MediaUri }}"
          }
          OutputBucketName = "{{ BucketName }}"
          OutputKey        = "{{ deriveTranscriptionIdentity.OutputPrefix }}"
          Subtitles = {
            Formats          = ["vtt"]
            OutputStartIndex = 1
          }
        }
      },
      {
        name           = "getJobAfterStartFailure"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        nextStep       = "validateJobAfterStartFailure"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "MediaUri"
            Selector = "$.TranscriptionJob.Media.MediaFileUri"
            Type     = "String"
          },
          {
            Name     = "LanguageCode"
            Selector = "$.TranscriptionJob.LanguageCode"
            Type     = "String"
          },
          {
            Name     = "MediaFormat"
            Selector = "$.TranscriptionJob.MediaFormat"
            Type     = "String"
          },
          {
            Name     = "SubtitleFormats"
            Selector = "$.TranscriptionJob.Subtitles.Formats"
            Type     = "StringList"
          },
          {
            Name     = "SubtitleStartIndex"
            Selector = "$.TranscriptionJob.Subtitles.OutputStartIndex"
            Type     = "Integer"
          },
        ]
      },
      {
        name   = "validateExistingJob"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              And = [
                {
                  Variable     = "{{ getExistingJob.MediaUri }}"
                  StringEquals = "{{ deriveTranscriptionIdentity.MediaUri }}"
                },
                {
                  Variable     = "{{ getExistingJob.LanguageCode }}"
                  StringEquals = "{{ LanguageCode }}"
                },
                {
                  Variable     = "{{ getExistingJob.MediaFormat }}"
                  StringEquals = "mp4"
                },
                {
                  Variable = "{{ getExistingJob.SubtitleFormats }}"
                  Contains = "vtt"
                },
                {
                  Variable      = "{{ getExistingJob.SubtitleStartIndex }}"
                  NumericEquals = 1
                },
              ]
              NextStep = "waitForTerminalState"
            },
          ]
          Default = "failExistingJobCollision"
        }
      },
      {
        name   = "validateJobAfterStartFailure"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              And = [
                {
                  Variable     = "{{ getJobAfterStartFailure.MediaUri }}"
                  StringEquals = "{{ deriveTranscriptionIdentity.MediaUri }}"
                },
                {
                  Variable     = "{{ getJobAfterStartFailure.LanguageCode }}"
                  StringEquals = "{{ LanguageCode }}"
                },
                {
                  Variable     = "{{ getJobAfterStartFailure.MediaFormat }}"
                  StringEquals = "mp4"
                },
                {
                  Variable = "{{ getJobAfterStartFailure.SubtitleFormats }}"
                  Contains = "vtt"
                },
                {
                  Variable      = "{{ getJobAfterStartFailure.SubtitleStartIndex }}"
                  NumericEquals = 1
                },
              ]
              NextStep = "waitForTerminalState"
            },
          ]
          Default = "failStartRaceCollision"
        }
      },
      {
        name           = "failExistingJobCollision"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "fail"
          Script  = local.fail_automation_script
          InputPayload = {
            Message = "Deterministic job name collision: the existing job does not match the requested object, language, format, or subtitle settings."
          }
        }
      },
      {
        name           = "failStartRaceCollision"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "fail"
          Script  = local.fail_automation_script
          InputPayload = {
            Message = "StartTranscriptionJob failed and the job subsequently found under the deterministic name does not match this request."
          }
        }
      },
      {
        name           = "waitForTerminalState"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 14400
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
          PropertySelector     = "$.TranscriptionJob.TranscriptionJobStatus"
          DesiredValues        = ["COMPLETED", "FAILED"]
        }
      },
      {
        name           = "getTerminalStatus"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "Status"
            Selector = "$.TranscriptionJob.TranscriptionJobStatus"
            Type     = "String"
          },
        ]
      },
      {
        name   = "chooseTerminalResult"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              NextStep     = "getCompletedJob"
              Variable     = "{{ getTerminalStatus.Status }}"
              StringEquals = "COMPLETED"
            },
          ]
          Default = "getFailedJob"
        }
      },
      {
        name           = "getCompletedJob"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "TranscriptFileUri"
            Selector = "$.TranscriptionJob.Transcript.TranscriptFileUri"
            Type     = "String"
          },
          {
            Name     = "SubtitleFileUris"
            Selector = "$.TranscriptionJob.Subtitles.SubtitleFileUris"
            Type     = "StringList"
          },
        ]
      },
      {
        name           = "probeSourceBeforeMaterialization"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ BucketName }}"
          Key     = "{{ ObjectKey }}"
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
        name   = "validateSourceBeforeMaterialization"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              NextStep     = "deriveTranscriptionArtifacts"
              Variable     = "{{ probeSourceBeforeMaterialization.VersionId }}"
              StringEquals = "{{ probeCurrentObject.VersionId }}"
            },
          ]
          Default = "failSourceChanged"
        }
      },
      {
        name           = "failSourceChanged"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "fail"
          Script  = local.fail_automation_script
          InputPayload = {
            Message = "The source object changed while transcription was running; a current-version execution must materialize its artifacts."
          }
        }
      },
      {
        name           = "deriveTranscriptionArtifacts"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Runtime = "python3.11"
          Handler = "materialize"
          Script  = local.derive_transcription_artifact_script
          InputPayload = {
            BucketName        = "{{ BucketName }}"
            Environment       = var.environment
            ObjectKey         = "{{ ObjectKey }}"
            ProjectName       = var.project_name
            TranscriptFileUri = "{{ getCompletedJob.TranscriptFileUri }}"
            SubtitleFileUris  = "{{ getCompletedJob.SubtitleFileUris }}"
            VersionId         = "{{ probeCurrentObject.VersionId }}"
          }
        }
        outputs = [
          {
            Name     = "JsonCopySource"
            Selector = "$.Payload.JsonCopySource"
            Type     = "String"
          },
          {
            Name     = "JsonKey"
            Selector = "$.Payload.JsonKey"
            Type     = "String"
          },
          {
            Name     = "JsonUri"
            Selector = "$.Payload.JsonUri"
            Type     = "String"
          },
          {
            Name     = "Tagging"
            Selector = "$.Payload.Tagging"
            Type     = "String"
          },
          {
            Name     = "VttCopySource"
            Selector = "$.Payload.VttCopySource"
            Type     = "String"
          },
          {
            Name     = "VttKey"
            Selector = "$.Payload.VttKey"
            Type     = "String"
          },
          {
            Name     = "VttUri"
            Selector = "$.Payload.VttUri"
            Type     = "String"
          },
        ]
      },
      {
        name           = "probeJsonArtifact"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:materializeJsonArtifact"
        onCancel       = "step:getCancellationState"
        nextStep       = "validateJsonArtifact"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ BucketName }}"
          Key     = "{{ deriveTranscriptionArtifacts.JsonKey }}"
        }
        outputs = [
          {
            Name     = "ContentType"
            Selector = "$.ContentType"
            Type     = "String"
          },
          {
            Name     = "SourceVersionId"
            Selector = "$.Metadata.sourceversionid"
            Type     = "String"
          },
        ]
      },
      {
        name   = "validateJsonArtifact"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              And = [
                {
                  Variable     = "{{ probeJsonArtifact.ContentType }}"
                  StringEquals = "application/json"
                },
                {
                  Variable     = "{{ probeJsonArtifact.SourceVersionId }}"
                  StringEquals = "{{ probeCurrentObject.VersionId }}"
                },
              ]
              NextStep = "probeVttArtifact"
            },
          ]
          Default = "materializeJsonArtifact"
        }
      },
      {
        name           = "materializeJsonArtifact"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service     = "s3"
          Api         = "CopyObject"
          Bucket      = "{{ BucketName }}"
          Key         = "{{ deriveTranscriptionArtifacts.JsonKey }}"
          CopySource  = "{{ deriveTranscriptionArtifacts.JsonCopySource }}"
          ContentType = "application/json"
          Metadata = {
            SourceVersionId = "{{ probeCurrentObject.VersionId }}"
          }
          MetadataDirective    = "REPLACE"
          ServerSideEncryption = "AES256"
          Tagging              = "{{ deriveTranscriptionArtifacts.Tagging }}"
          TaggingDirective     = "REPLACE"
        }
      },
      {
        name           = "probeVttArtifact"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:materializeVttArtifact"
        onCancel       = "step:getCancellationState"
        nextStep       = "validateVttArtifact"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ BucketName }}"
          Key     = "{{ deriveTranscriptionArtifacts.VttKey }}"
        }
        outputs = [
          {
            Name     = "ContentType"
            Selector = "$.ContentType"
            Type     = "String"
          },
          {
            Name     = "SourceVersionId"
            Selector = "$.Metadata.sourceversionid"
            Type     = "String"
          },
        ]
      },
      {
        name   = "validateVttArtifact"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              And = [
                {
                  Variable     = "{{ probeVttArtifact.ContentType }}"
                  StringEquals = "text/vtt; charset=utf-8"
                },
                {
                  Variable     = "{{ probeVttArtifact.SourceVersionId }}"
                  StringEquals = "{{ probeCurrentObject.VersionId }}"
                },
              ]
              NextStep = "convergenceComplete"
            },
          ]
          Default = "materializeVttArtifact"
        }
      },
      {
        name           = "materializeVttArtifact"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        isEnd          = true
        inputs = {
          Service     = "s3"
          Api         = "CopyObject"
          Bucket      = "{{ BucketName }}"
          Key         = "{{ deriveTranscriptionArtifacts.VttKey }}"
          CopySource  = "{{ deriveTranscriptionArtifacts.VttCopySource }}"
          ContentType = "text/vtt; charset=utf-8"
          Metadata = {
            SourceVersionId = "{{ probeCurrentObject.VersionId }}"
          }
          MetadataDirective    = "REPLACE"
          ServerSideEncryption = "AES256"
          Tagging              = "{{ deriveTranscriptionArtifacts.Tagging }}"
          TaggingDirective     = "REPLACE"
        }
      },
      {
        name   = "convergenceComplete"
        action = "aws:sleep"
        isEnd  = true
        inputs = {
          Duration = "PT1S"
        }
      },
      {
        name           = "getFailedJob"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        onFailure      = "Abort"
        onCancel       = "step:getCancellationState"
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "FailureReason"
            Selector = "$.TranscriptionJob.FailureReason"
            Type     = "String"
          },
        ]
      },
      {
        name           = "surfaceFailureReason"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "fail"
          Script  = local.fail_automation_script
          InputPayload = {
            Message = "Amazon Transcribe failed: {{ getFailedJob.FailureReason }}"
          }
        }
      },
      {
        name           = "getCancellationState"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 1
        onFailure      = "Abort"
        onCancel       = "Abort"
        isEnd          = true
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = "{{ deriveTranscriptionIdentity.JobName }}"
        }
        outputs = [
          {
            Name     = "StatusWhenCancelled"
            Selector = "$.TranscriptionJob.TranscriptionJobStatus"
            Type     = "String"
          },
        ]
      },
    ]
  })
}
