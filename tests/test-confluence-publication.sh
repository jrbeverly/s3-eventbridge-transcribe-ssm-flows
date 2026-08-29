#!/usr/bin/env bash
set -euo pipefail
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
awk '$0 ~ "  confluence_publication_script = <<-PYTHON" { capture = 1; next } capture && $0 == "  PYTHON" { exit } capture { sub(/^    /, ""); print }' "$repository_root/confluence.tf" > "$temporary_directory/publisher.py"
cat >> "$temporary_directory/publisher.py" <<'PYTHON'
import io
import types

class FakeSecrets:
    def get_secret_value(self, SecretId):
        assert SecretId == "secret-arn"
        return {"SecretString": '{"email":"person@example.com","api_token":"super-secret"}'}

class FakeS3:
    def get_object(self, **kwargs):
        assert kwargs == {"Bucket": "source", "Key": "path/demo.transcription.vtt", "VersionId": "vtt-version"}
        return {"Body": io.BytesIO(b"WEBVTT\n\n00:00.000 --> 00:01.000\ncomplete <text>\n")}

class FakeSsm:
    output = {}
    def get_automation_execution(self, AutomationExecutionId):
        assert AutomationExecutionId == "readiness-execution"
        return {"AutomationExecution": {"Outputs": self.output}}

def aws_client(name):
    return {"secretsmanager": FakeSecrets, "s3": FakeS3, "ssm": FakeSsm}[name]()

boto3 = types.SimpleNamespace(client=aws_client)

class FakeConfluence:
    pages, labels, creates, ambiguous_create = {}, {}, 0, True
    def __init__(self, origin, email, token):
        assert (origin, email, token) == ("https://example.atlassian.net", "person@example.com", "super-secret")
        self.observations = []
    def call(self, method, path, payload=None, expected=(200,)):
        self.observations.append({"method": method, "path": path.split("?", 1)[0], "status": 200})
        if path.startswith("/wiki/rest/api/content/search") or path.startswith("/wiki/api/v2/pages?"):
            return {"results": ([{"id": "42"}] if self.pages else [])}
        if method == "POST" and path == "/wiki/api/v2/pages":
            type(self).creates += 1
            page = {"id": "42", "title": payload["title"], "body": payload["body"], "version": {"number": 1}, "_links": {"webui": "/wiki/spaces/S/pages/42"}}
            self.pages["42"], self.labels["42"] = page, set()
            if type(self).ambiguous_create:
                type(self).ambiguous_create = False
                raise RuntimeError("ambiguous create response")
            return page
        if method == "GET" and path.startswith("/wiki/api/v2/pages/42"):
            return self.pages["42"]
        if method == "PUT" and path == "/wiki/api/v2/pages/42":
            page = {"id": "42", "title": payload["title"], "body": payload["body"], "version": {"number": payload["version"]["number"]}, "_links": {"webui": "/wiki/spaces/S/pages/42"}}
            self.pages["42"] = page
            return page
        if method == "GET" and path == "/wiki/rest/api/content/42/label?limit=200":
            return {"results": [{"name": item} for item in self.labels["42"]]}
        if method == "POST" and path == "/wiki/rest/api/content/42/label":
            self.labels["42"].update(item["name"] for item in payload)
            return {}
        if method == "DELETE" and path.startswith("/wiki/rest/api/content/42/label/"):
            self.labels["42"].remove(parse.unquote(path.rsplit("/", 1)[1]))
            return None
        raise AssertionError((method, path, payload))

Confluence = FakeConfluence

def readiness(properties):
    return {"evaluateReadiness.Ready": ["true"], "evaluateReadiness.SourceIdentity": ['{"BucketName":"source","ObjectKey":"path/demo.mp4","VersionId":"source-version","ETag":"etag"}'], "evaluateReadiness.SourceProperties": [json.dumps(properties)], "evaluateReadiness.VttLocation": ['{"BucketName":"source","ObjectKey":"path/demo.transcription.vtt","VersionId":"vtt-version"}'], "evaluateReadiness.DestinationFacts": ['{"DestinationType":"s3","DestinationId":"path/demo.mp4","MediaUrl":"https://media.example/path/demo.mp4","ConcurrencyToken":"destination-version"}'], "evaluateReadiness.NotReadyReasons": []}

def event(properties):
    FakeSsm.output = readiness(properties)
    return {"ReadinessExecutionId": "readiness-execution", "CredentialsSecretArn": "secret-arn", "ConfluenceBaseUrl": "https://example.atlassian.net", "ConfluenceSpaceId": "123"}

first = publish(event({"Team Name": "R&D", "participants": "A,B"}), None)
assert first["Published"] is True and first["Operation"] in {"created", "unchanged"}
assert first["PageId"] == "42" and first["PageUrl"].endswith("/pages/42")
body = FakeConfluence.pages["42"]["body"]["value"]
assert "WEBVTT" in body and "complete &lt;text&gt;" in body
assert "Open published media" in body and "https://media.example/path/demo.mp4" in body
assert "destination-version" in body and "source-version" in body
assert "Team Name" in body and "R&amp;D" in body
assert len([label for label in FakeConfluence.labels["42"] if label.startswith("srcprop-")]) == 2
second = publish(event({"Team Name": "R&D", "participants": "A,B"}), None)
assert second["Operation"] == "unchanged" and FakeConfluence.creates == 1
assert FakeConfluence.pages["42"]["version"]["number"] == 1
third = publish(event({"Team Name": "Platform"}), None)
assert third["Operation"] == "updated" and FakeConfluence.creates == 1
assert FakeConfluence.pages["42"]["version"]["number"] == 2
assert len([label for label in FakeConfluence.labels["42"] if label.startswith("srcprop-")]) == 1
assert "super-secret" not in json.dumps(third) and "person@example.com" not in json.dumps(third)
not_ready_event = event({})
FakeSsm.output = {"evaluateReadiness.Ready": ["false"], "evaluateReadiness.NotReadyReasons": ["VTT_MISSING"]}
not_ready = publish(not_ready_event, None)
assert not_ready["Published"] is False and not_ready["NotReadyReasons"] == ["VTT_MISSING"]
assert not_ready["Operation"] == "not-ready" and not_ready["PageId"] == ""
assert property_label("A B", "C/D").startswith("srcprop-a-b-c-d-")
assert len(property_label("x" * 500, "y" * 500)) <= 221
print("PASS: complete VTT, media identity, source context, and exact properties are rendered safely")
print("PASS: deterministic source discovery updates one page and reconciles normalized labels")
print("PASS: an ambiguous concurrent create is rediscovered instead of creating a second page")
print("PASS: runtime credentials and sensitive values are absent from publisher results")
print("PASS: not-ready upstream state remains unchanged and retryable")
PYTHON
python3 "$temporary_directory/publisher.py"
grep -q 'action = "aws:executeAutomation"' "$repository_root/confluence.tf"
grep -q 'secretsmanager:GetSecretValue' "$repository_root/confluence.tf"
grep -q 'Resource = var.confluence_credentials_secret_arn' "$repository_root/confluence.tf"
grep -q 'ConfluenceSpaceId    = "{{ ConfluenceSpaceId }}"' "$repository_root/confluence.tf"
if grep -q 'PutObject\|DeleteObject\|PutObjectAnnotation' "$repository_root/confluence.tf"; then
  echo "FAIL: Confluence publisher must not mutate upstream S3 state" >&2
  exit 1
fi
echo "PASS: Automation invokes readiness and has read-only upstream permissions"
