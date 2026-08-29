locals {
  derive_readiness_vtt_key_script = <<-PYTHON
    def derive(events, context):
        key = events["SourceObjectKey"]
        return {"VttObjectKey": key[:-4] + ".transcription.vtt"}
  PYTHON

  evaluate_object_readiness_script = join("", [local.s3_annotation_model_prelude, <<-PYTHON
    import boto3
    from botocore.exceptions import ClientError
    from urllib.parse import urlsplit

    MISSING_CODES = {"404", "NoSuchAnnotation", "NoSuchKey", "NoSuchVersion", "NotFound"}

    def error_code(error):
        return error.response.get("Error", {}).get("Code", "")

    def empty_result(bucket, key):
        return {
            "Ready": False,
            "SourceIdentity": {"BucketName": bucket, "ObjectKey": key},
            "SourceProperties": {},
            "VttLocation": {},
            "DestinationFacts": {},
            "NotReadyReasons": [],
        }

    def annotation(s3, bucket, key, version_id, name):
        try:
            response = s3.get_object_annotation(
                Bucket=bucket,
                Key=key,
                VersionId=version_id,
                AnnotationName=name,
            )
            value = response["AnnotationPayload"].read().decode("utf-8")
            return value if value else None, None
        except UnicodeDecodeError:
            return None, "malformed"
        except ClientError as error:
            if error_code(error) in MISSING_CODES:
                return None, "missing"
            return None, "unavailable"

    def safe_https_url(value):
        if not value or any(character.isspace() or ord(character) < 32 for character in value):
            return False
        try:
            parsed = urlsplit(value)
            return parsed.scheme == "https" and bool(parsed.netloc)
        except ValueError:
            return False

    def evaluate(events, context):
        s3 = boto3.client("s3")
        bucket = events["SourceBucketName"]
        key = events["SourceObjectKey"]
        destination_bucket = events["PublicationBucketName"]
        result = empty_result(bucket, key)
        reasons = result["NotReadyReasons"]

        try:
            current = s3.head_object(Bucket=bucket, Key=key)
        except ClientError as error:
            if error_code(error) in MISSING_CODES:
                reasons.append("SOURCE_MISSING")
                return result
            reasons.append("SOURCE_PROPERTIES_UNREADABLE")
            return result

        version_id = current.get("VersionId")
        etag = current.get("ETag", "")
        content_type = current.get("ContentType", "")
        result["SourceIdentity"].update({
            "VersionId": version_id or "",
            "ETag": etag,
            "ContentType": content_type,
            "ContentLength": str(current.get("ContentLength", "")),
        })
        if not key.lower().endswith(".mp4") or content_type.lower() != "video/mp4":
            reasons.append("SOURCE_NOT_MP4")
        if not version_id or version_id == "null":
            reasons.append("SOURCE_VERSION_UNAVAILABLE")
            return result

        try:
            pinned = s3.head_object(
                Bucket=bucket,
                Key=key,
                VersionId=version_id,
                IfMatch=etag,
            )
            result["SourceProperties"] = pinned.get("Metadata", {})
        except ClientError as error:
            if error_code(error) in {"PreconditionFailed", "412"}:
                reasons.append("SOURCE_CHANGED")
            else:
                reasons.append("SOURCE_PROPERTIES_UNREADABLE")

        vtt_key = key[:-4] + ".transcription.vtt" if key.lower().endswith(".mp4") else ""
        if vtt_key:
            try:
                vtt = s3.head_object(Bucket=bucket, Key=vtt_key)
                result["VttLocation"] = {
                    "BucketName": bucket,
                    "ObjectKey": vtt_key,
                    "VersionId": vtt.get("VersionId", ""),
                    "ETag": vtt.get("ETag", ""),
                    "ContentType": vtt.get("ContentType", ""),
                    "ContentLength": str(vtt.get("ContentLength", "")),
                }
                malformed_vtt = (vtt.get("ContentType") != "text/vtt; charset=utf-8"
                                 or vtt.get("ContentLength", 0) <= 0
                                 or not vtt.get("VersionId"))
                if not malformed_vtt:
                    try:
                        vtt_body = s3.get_object(
                            Bucket=bucket,
                            Key=vtt_key,
                            VersionId=vtt["VersionId"],
                        )["Body"].read().decode("utf-8")
                        if not vtt_body.startswith("WEBVTT"):
                            malformed_vtt = True
                    except (ClientError, UnicodeDecodeError):
                        malformed_vtt = True
                if malformed_vtt:
                    reasons.append("VTT_MALFORMED")
                if vtt.get("Metadata", {}).get("sourceversionid") != version_id:
                    reasons.append("VTT_STALE")
            except ClientError as error:
                reasons.append("VTT_MISSING" if error_code(error) in MISSING_CODES
                               else "VTT_MALFORMED")

        annotation_specs = (
            ("publication.destination", "DestinationType", "PUBLICATION_DESTINATION_MISSING"),
            ("publication.id", "DestinationId", "PUBLICATION_ID_MISSING"),
            ("publication.url", "MediaUrl", "PUBLICATION_URL_MISSING"),
            ("publication.concurrency-token", "ConcurrencyToken", None),
        )
        states = {}
        for name, output_name, missing_reason in annotation_specs:
            value, state = annotation(s3, bucket, key, version_id, name)
            states[output_name] = state
            if value is not None:
                result["DestinationFacts"][output_name] = value
            elif missing_reason:
                reasons.append(missing_reason)

        media_url = result["DestinationFacts"].get("MediaUrl")
        if media_url is not None and not safe_https_url(media_url):
            reasons.append("PUBLICATION_URL_MALFORMED")

        destination_type = result["DestinationFacts"].get("DestinationType")
        destination_id = result["DestinationFacts"].get("DestinationId")
        concurrency_token = result["DestinationFacts"].get("ConcurrencyToken")
        if destination_type and destination_type != "s3":
            reasons.append("PUBLICATION_DESTINATION_UNSUPPORTED")
        elif destination_type == "s3" and destination_id:
            if not concurrency_token:
                reasons.append("PUBLICATION_STALE")
            else:
                try:
                    destination = s3.head_object(
                        Bucket=destination_bucket,
                        Key=destination_id,
                        VersionId=concurrency_token,
                    )
                    result["DestinationFacts"].update({
                        "BucketName": destination_bucket,
                        "ETag": destination.get("ETag", ""),
                        "ContentLength": str(destination.get("ContentLength", "")),
                    })
                    if (destination.get("ETag") != etag
                            or destination.get("ContentLength") != current.get("ContentLength")):
                        reasons.append("PUBLICATION_STALE")
                except ClientError as error:
                    reasons.append("PUBLICATION_DESTINATION_UNAVAILABLE"
                                   if error_code(error) not in MISSING_CODES
                                   else "PUBLICATION_STALE")

        try:
            latest = s3.head_object(Bucket=bucket, Key=key, IfMatch=etag)
            if latest.get("VersionId") != version_id:
                reasons.append("SOURCE_CHANGED")
        except ClientError as error:
            if error_code(error) in {"PreconditionFailed", "412"}:
                reasons.append("SOURCE_CHANGED")
            else:
                reasons.append("SOURCE_PROPERTIES_UNREADABLE")

        result["NotReadyReasons"] = list(dict.fromkeys(reasons))
        result["Ready"] = not result["NotReadyReasons"]
        return result
  PYTHON
  ])
}

resource "aws_iam_role" "object_readiness" {
  name = "${var.environment}-object-readiness"

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

resource "aws_iam_role_policy" "object_readiness" {
  name = "inspect-object-readiness"
  role = aws_iam_role.object_readiness.id

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
        ]
        Resource = "${aws_s3_bucket.source.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
        ]
        Resource = "${aws_s3_bucket.publication_adapter.arn}/*"
      },
    ]
  })
}

resource "aws_ssm_document" "object_readiness" {
  name            = "${var.environment}-evaluate-object-readiness"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Inspect one current source object and return its version-bound Confluence publication readiness without performing transcription or destination publication."
    assumeRole    = aws_iam_role.object_readiness.arn
    parameters = {
      SourceBucketName = {
        type           = "String"
        description    = "S3 bucket containing the source MP4. The Automation role is scoped to the Terraform-managed source bucket."
        default        = aws_s3_bucket.source.id
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      SourceObjectKey = {
        type           = "String"
        description    = "Exact, literal key of the source object to evaluate."
        allowedPattern = "^.+$"
      }
    }
    outputs = [
      "evaluateReadiness.Ready",
      "evaluateReadiness.SourceIdentity",
      "evaluateReadiness.SourceProperties",
      "evaluateReadiness.VttLocation",
      "evaluateReadiness.DestinationFacts",
      "evaluateReadiness.NotReadyReasons",
    ]
    mainSteps = [
      {
        name           = "probeSourceNatively"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:evaluateReadiness"
        nextStep       = "validateNativeSource"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ SourceBucketName }}"
          Key     = "{{ SourceObjectKey }}"
        }
        outputs = [
          {
            Name     = "ContentType"
            Selector = "$.ContentType"
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
        name   = "validateNativeSource"
        action = "aws:branch"
        inputs = {
          Choices = [{
            And = [
              {
                Variable     = "{{ probeSourceNatively.ContentType }}"
                StringEquals = "video/mp4"
              },
              {
                Not = {
                  Variable     = "{{ probeSourceNatively.VersionId }}"
                  StringEquals = ""
                }
              },
            ]
            NextStep = "deriveVttKey"
          }]
          Default = "evaluateReadiness"
        }
      },
      {
        name           = "deriveVttKey"
        action         = "aws:executeScript"
        timeoutSeconds = 30
        maxAttempts    = 1
        onFailure      = "Abort"
        inputs = {
          Runtime = "python3.11"
          Handler = "derive"
          Script  = local.derive_readiness_vtt_key_script
          InputPayload = {
            SourceObjectKey = "{{ SourceObjectKey }}"
          }
        }
        outputs = [{
          Name     = "VttObjectKey"
          Selector = "$.Payload.VttObjectKey"
          Type     = "String"
        }]
      },
      {
        name           = "probeVttNatively"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        maxAttempts    = 3
        isCritical     = false
        onFailure      = "step:evaluateReadiness"
        nextStep       = "evaluateReadiness"
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ SourceBucketName }}"
          Key     = "{{ deriveVttKey.VttObjectKey }}"
        }
      },
      {
        name           = "evaluateReadiness"
        action         = "aws:executeScript"
        timeoutSeconds = 60
        maxAttempts    = 3
        onFailure      = "Abort"
        isEnd          = true
        inputs = {
          Runtime = "python3.11"
          Handler = "evaluate"
          Script  = local.evaluate_object_readiness_script
          InputPayload = {
            PublicationBucketName = aws_s3_bucket.publication_adapter.id
            SourceBucketName      = "{{ SourceBucketName }}"
            SourceObjectKey       = "{{ SourceObjectKey }}"
          }
        }
        outputs = [
          {
            Name     = "Ready"
            Selector = "$.Payload.Ready"
            Type     = "Boolean"
          },
          {
            Name     = "SourceIdentity"
            Selector = "$.Payload.SourceIdentity"
            Type     = "StringMap"
          },
          {
            Name     = "SourceProperties"
            Selector = "$.Payload.SourceProperties"
            Type     = "StringMap"
          },
          {
            Name     = "VttLocation"
            Selector = "$.Payload.VttLocation"
            Type     = "StringMap"
          },
          {
            Name     = "DestinationFacts"
            Selector = "$.Payload.DestinationFacts"
            Type     = "StringMap"
          },
          {
            Name     = "NotReadyReasons"
            Selector = "$.Payload.NotReadyReasons"
            Type     = "StringList"
          },
        ]
      },
    ]
  })
}
