locals {
  confluence_publication_script = <<-PYTHON
    import base64
    import hashlib
    import html
    import json
    import re
    import time
    from urllib import error, parse, request

    import boto3

    TRANSIENT = {429, 500, 502, 503, 504}

    def source_marker(bucket, key):
        digest = hashlib.sha256((bucket + "\0" + key).encode("utf-8")).hexdigest()
        return "source-" + digest[:32]

    def property_label(key, value):
        original = str(key) + "=" + str(value)
        normalized = re.sub(r"[^a-z0-9]+", "-", original.lower()).strip("-")
        normalized = normalized[:200].rstrip("-") or "empty"
        digest = hashlib.sha256(original.encode("utf-8")).hexdigest()[:12]
        return "srcprop-" + normalized + "-" + digest

    def storage_body(identity, properties, destination, vtt, marker):
        escape = lambda value: html.escape(str(value), quote=False)
        property_rows = "".join(
            "<tr><td>" + escape(key) + "</td><td>" + escape(value) + "</td></tr>"
            for key, value in sorted(properties.items()))
        return (
            "<p>Source identity: <code>" + escape(identity["BucketName"] + "/" + identity["ObjectKey"])
            + "</code></p><ul><li>Source version: <code>" + escape(identity["VersionId"])
            + "</code></li><li>Source ETag: <code>" + escape(identity.get("ETag", ""))
            + "</code></li><li>Publication destination: <code>" + escape(destination["DestinationType"])
            + "</code></li><li>Destination ID: <code>" + escape(destination["DestinationId"])
            + "</code></li><li>Destination revision: <code>" + escape(destination.get("ConcurrencyToken", ""))
            + "</code></li></ul><p><a href=\"" + html.escape(destination["MediaUrl"], quote=True)
            + "\">Open published media</a></p><h2>Source properties</h2><table><tbody>"
            + property_rows + "</tbody></table><h2>Transcription</h2><pre>"
            + escape(vtt) + "</pre><p><small>Reconciliation identity: <code>"
            + marker + "</code></small></p>")

    class Confluence:
        def __init__(self, origin, email, token, sleep=time.sleep):
            parsed = parse.urlparse(origin)
            if (parsed.scheme != "https" or not parsed.hostname
                    or not parsed.hostname.endswith(".atlassian.net")
                    or parsed.path or parsed.params or parsed.query or parsed.fragment):
                raise ValueError("Confluence origin is not an https://*.atlassian.net origin")
            self.origin = origin
            encoded = base64.b64encode((email + ":" + token).encode()).decode()
            self.authorization = "Basic " + encoded
            self.sleep = sleep
            self.observations = []

        def call(self, method, path, payload=None, expected=(200,)):
            body = None if payload is None else json.dumps(payload).encode("utf-8")
            for attempt in range(4):
                req = request.Request(self.origin + path, data=body, method=method)
                req.add_header("Accept", "application/json")
                req.add_header("Authorization", self.authorization)
                if body is not None:
                    req.add_header("Content-Type", "application/json")
                try:
                    response = request.urlopen(req, timeout=30)
                    status, headers, raw = response.status, response.headers, response.read()
                except error.HTTPError as exc:
                    status, headers, raw = exc.code, exc.headers, exc.read()
                safe_path = path.split("?", 1)[0]
                self.observations.append({"method": method, "path": safe_path, "status": status})
                if status in TRANSIENT and attempt < 3:
                    retry_after = headers.get("Retry-After", "1")
                    delay = int(retry_after) if retry_after.isdigit() else 2 ** attempt
                    self.sleep(min(max(delay, 1), 30))
                    continue
                if status not in expected:
                    raise RuntimeError("Confluence " + method + " " + safe_path
                                       + " returned HTTP " + str(status))
                return json.loads(raw) if raw else None
            raise AssertionError("unreachable")

    def output_value(readiness, name):
        value = readiness.get(name, readiness.get("evaluateReadiness." + name))
        if name != "NotReadyReasons" and isinstance(value, list) and len(value) == 1:
            value = value[0]
        if isinstance(value, str) and value[:1] in "[{":
            return json.loads(value)
        if name == "Ready" and isinstance(value, str):
            return value.lower() == "true"
        return value

    def find_page(client, space_id, marker, title):
        found = {}
        requests = [
            "/wiki/rest/api/content/search?cql="
            + parse.quote(f'type=page and label="{marker}"') + "&limit=2",
            "/wiki/api/v2/pages?space-id=" + parse.quote(str(space_id), safe="")
            + "&title=" + parse.quote(title, safe="") + "&limit=2",
        ]
        for path in requests:
            response = client.call("GET", path)
            for page in response.get("results", []):
                found[str(page["id"])] = page
            if found:
                break
        if len(found) > 1:
            raise RuntimeError("multiple Confluence pages match the source identity")
        return next(iter(found.values()), None)

    def reconcile_labels(client, page_id, desired):
        response = client.call("GET", "/wiki/rest/api/content/" + page_id + "/label?limit=200")
        current = {item["name"] for item in response.get("results", [])}
        for label in sorted(current - desired):
            if label.startswith("srcprop-"):
                client.call("DELETE", "/wiki/rest/api/content/" + page_id + "/label/"
                            + parse.quote(label, safe=""), expected=(204,))
        missing = sorted(desired - current)
        if missing:
            client.call("POST", "/wiki/rest/api/content/" + page_id + "/label",
                        [{"prefix": "global", "name": label} for label in missing],
                        expected=(200, 201))

    def publish(events, context):
        execution = boto3.client("ssm").get_automation_execution(
            AutomationExecutionId=events["ReadinessExecutionId"])
        readiness = execution["AutomationExecution"].get("Outputs", {})
        if not output_value(readiness, "Ready"):
            return {"Published": False, "PageId": "", "PageUrl": "",
                    "PageVersion": "", "Operation": "not-ready", "Observations": [],
                    "NotReadyReasons": output_value(readiness, "NotReadyReasons") or []}
        identity = output_value(readiness, "SourceIdentity")
        properties = output_value(readiness, "SourceProperties") or {}
        vtt_location = output_value(readiness, "VttLocation")
        destination = output_value(readiness, "DestinationFacts")

        secret_value = boto3.client("secretsmanager").get_secret_value(
            SecretId=events["CredentialsSecretArn"])["SecretString"]
        credentials = json.loads(secret_value)
        email, token = credentials["email"], credentials["api_token"]
        if not email or not token:
            raise ValueError("Confluence credential secret fields must not be empty")

        vtt = boto3.client("s3").get_object(
            Bucket=vtt_location["BucketName"], Key=vtt_location["ObjectKey"],
            VersionId=vtt_location["VersionId"])["Body"].read().decode("utf-8")
        if not vtt.startswith("WEBVTT"):
            raise ValueError("pinned transcription is not complete WEBVTT content")

        marker = source_marker(identity["BucketName"], identity["ObjectKey"])
        title = "Media transcription " + marker
        body = storage_body(identity, properties, destination, vtt, marker)
        client = Confluence(events["ConfluenceBaseUrl"], email, token)
        page = find_page(client, events["ConfluenceSpaceId"], marker, title)
        operation = "unchanged"
        if page is None:
            try:
                page = client.call("POST", "/wiki/api/v2/pages", {
                    "spaceId": events["ConfluenceSpaceId"], "status": "current",
                    "title": title, "body": {"representation": "storage", "value": body}},
                    expected=(200, 201))
                operation = "created"
            except RuntimeError:
                page = find_page(client, events["ConfluenceSpaceId"], marker, title)
                if page is None:
                    raise
        page_id = str(page["id"])
        fetched = client.call("GET", "/wiki/api/v2/pages/" + page_id + "?body-format=storage")
        fetched_body = fetched.get("body", {})
        current_body = fetched_body.get("storage", fetched_body).get("value", "")
        if current_body != body or fetched.get("title") != title:
            page = client.call("PUT", "/wiki/api/v2/pages/" + page_id, {
                "id": page_id, "status": "current", "title": title,
                "body": {"representation": "storage", "value": body},
                "version": {"number": fetched["version"]["number"] + 1,
                            "message": "Reconcile source media transcription"}})
            operation = "updated"
        else:
            page = fetched
        desired_labels = {marker} | {property_label(key, value)
                                     for key, value in properties.items()}
        reconcile_labels(client, page_id, desired_labels)
        webui = page.get("_links", {}).get("webui", "/wiki/pages/viewpage.action?pageId=" + page_id)
        return {"Published": True, "PageId": page_id,
                "PageUrl": parse.urljoin(events["ConfluenceBaseUrl"] + "/", webui),
                "PageVersion": str(page["version"]["number"]),
                "Operation": operation, "Observations": client.observations}
  PYTHON
}

resource "aws_iam_role" "confluence_publication" {
  name = "${var.environment}-confluence-publication"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "confluence_publication" {
  name = "reconcile-confluence-page"
  role = aws_iam_role.confluence_publication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.object_readiness.name}:$DEFAULT",
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.object_readiness.name}",
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetAutomationExecution"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.object_readiness.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.source.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.confluence_credentials_secret_arn
      },
    ]
  })
}

resource "aws_ssm_document" "confluence_publication" {
  name            = "${var.environment}-reconcile-confluence-publication"
  document_type   = "Automation"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Reconcile one ready source object to one idempotently identified Confluence page."
    assumeRole    = aws_iam_role.confluence_publication.arn
    parameters = {
      SourceBucketName = {
        type           = "String", default = aws_s3_bucket.source.id,
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
      }
      SourceObjectKey = { type = "String", allowedPattern = "^.+$" }
      ConfluenceSpaceId = {
        type           = "String"
        default        = var.confluence_space_id
        description    = "Opaque destination space ID; override only for an independently invoked reconciliation."
        allowedPattern = "^.+$"
      }
    }
    outputs = ["publish.Published", "publish.PageId", "publish.PageUrl",
    "publish.PageVersion", "publish.Operation", "publish.Observations", "publish.NotReadyReasons"]
    mainSteps = [
      {
        name           = "evaluateReadiness", action = "aws:executeAutomation",
        timeoutSeconds = 180, maxAttempts = 1, onFailure = "Abort",
        inputs = {
          DocumentName = aws_ssm_document.object_readiness.name
          RuntimeParameters = {
            SourceBucketName = ["{{ SourceBucketName }}"]
            SourceObjectKey  = ["{{ SourceObjectKey }}"]
          }
        }
      },
      {
        name        = "publish", action = "aws:executeScript", timeoutSeconds = 600,
        maxAttempts = 1, onFailure = "Abort", isEnd = true,
        inputs = {
          Runtime = "python3.11", Handler = "publish",
          Script  = local.confluence_publication_script,
          InputPayload = {
            ReadinessExecutionId = "{{ evaluateReadiness.ExecutionId }}"
            ConfluenceBaseUrl    = var.confluence_base_url
            ConfluenceSpaceId    = "{{ ConfluenceSpaceId }}"
            CredentialsSecretArn = var.confluence_credentials_secret_arn
          }
        }
        outputs = [
          { Name = "Published", Selector = "$.Payload.Published", Type = "Boolean" },
          { Name = "PageId", Selector = "$.Payload.PageId", Type = "String" },
          { Name = "PageUrl", Selector = "$.Payload.PageUrl", Type = "String" },
          { Name = "PageVersion", Selector = "$.Payload.PageVersion", Type = "String" },
          { Name = "Operation", Selector = "$.Payload.Operation", Type = "String" },
          { Name = "Observations", Selector = "$.Payload.Observations", Type = "MapList" },
          { Name = "NotReadyReasons", Selector = "$.Payload.NotReadyReasons", Type = "StringList" },
        ]
      },
    ]
  })
}
