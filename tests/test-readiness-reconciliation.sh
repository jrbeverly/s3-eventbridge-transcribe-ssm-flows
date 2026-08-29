#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
reconciliation_file="$repository_root/reconciliation.tf"
pattern_template="$repository_root/event-patterns/readiness-hint.json.tftpl"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

extract_script() {
  awk '
    $0 ~ "  dispatch_readiness_reconciliation_script = <<-PYTHON" { capture = 1; next }
    capture && $0 == "  PYTHON" { exit }
    capture { sub(/^    /, ""); print }
  ' "$reconciliation_file"
}

{
  cat <<'PYTHON'
import sys
import types


class FakeS3:
    def __init__(self):
        self.requests = []

    def list_objects_v2(self, **request):
        self.requests.append(request)
        if request.get("Prefix") == "path/recording":
            return {
                "Contents": [
                    {"Key": "path/recording.transcription.vtt"},
                    {"Key": "path/recording.MP4"},
                ],
                "IsTruncated": False,
            }
        if "ContinuationToken" not in request:
            return {
                "Contents": [{"Key": "a.mp4"}, {"Key": "a.transcription.vtt"}],
                "IsTruncated": True,
                "NextContinuationToken": "next",
            }
        return {
            "Contents": [{"Key": "nested/B.MP4"}, {"Key": "ignore.txt"}],
            "IsTruncated": False,
        }


class FakeSsm:
    def __init__(self):
        self.requests = []

    def start_automation_execution(self, **request):
        self.requests.append(request)
        return {"AutomationExecutionId": f"execution-{len(self.requests)}"}


s3, ssm = FakeS3(), FakeSsm()
boto3 = types.ModuleType("boto3")
boto3.client = lambda service: {"s3": s3, "ssm": ssm}[service]
sys.modules["boto3"] = boto3
PYTHON
  extract_script
  cat <<'PYTHON'

base = {
    "SourceBucketName": "source-bucket",
    "ConfluencePublicationDocumentName": "publish-confluence",
}

hint = dispatch({**base, "ChangedObjectKey": "path/recording.transcription.vtt"}, None)
assert hint == {
    "CandidateCount": 1,
    "ListRequestCount": 1,
    "ExecutionIds": ["execution-1"],
}
assert ssm.requests[-1] == {
    "DocumentName": "publish-confluence",
    "Parameters": {
        "SourceBucketName": ["source-bucket"],
        "SourceObjectKey": ["path/recording.MP4"],
    },
}

duplicate = dispatch({**base, "ChangedObjectKey": "path/recording.mp4"}, None)
assert duplicate["CandidateCount"] == 1
assert ssm.requests[-1]["DocumentName"] == "publish-confluence"
assert ssm.requests[-1]["Parameters"]["SourceObjectKey"] == ["path/recording.mp4"]
print("PASS: duplicate MP4 and VTT hints invoke the same per-object publisher")

scheduled = dispatch({**base, "ChangedObjectKey": ""}, None)
assert scheduled["CandidateCount"] == 2
assert scheduled["ListRequestCount"] == 2
assert s3.requests == [
    {"Bucket": "source-bucket", "Prefix": "path/recording", "MaxKeys": 1000},
    {"Bucket": "source-bucket", "MaxKeys": 1000},
    {"Bucket": "source-bucket", "MaxKeys": 1000, "ContinuationToken": "next"},
]
assert [request["Parameters"]["SourceObjectKey"][0]
        for request in ssm.requests[-2:]] == ["a.mp4", "nested/B.MP4"]
assert all(request["DocumentName"] == "publish-confluence"
           for request in ssm.requests)
print("PASS: scheduled discovery paginates bounded S3 listings into the readiness-gated publisher")
PYTHON
} > "$temporary_directory/test_reconciliation.py"

python3 "$temporary_directory/test_reconciliation.py"

pattern_file="$temporary_directory/readiness-hint.json"
sed 's/${source_bucket_name}/"source-bucket"/' "$pattern_template" > "$pattern_file"
jq -e '
  .source == ["aws.s3"] and
  (."detail-type" | sort) == (["Object Annotation Created", "Object Annotation Removed", "Object Created"] | sort) and
  .detail.bucket.name == ["source-bucket"] and
  (.detail.object.key | length) == 2 and
  any(.detail.object.key[]; .suffix."equals-ignore-case" == ".mp4") and
  any(.detail.object.key[]; .suffix."equals-ignore-case" == ".transcription.vtt")
' "$pattern_file" >/dev/null

if grep -Eq 'PutObject|CopyObject|PutObjectAnnotation|StartTranscriptionJob' "$reconciliation_file"; then
  echo "FAIL: readiness trigger writes source state or starts upstream work" >&2
  exit 1
fi

echo "PASS: hint pattern is source-scoped and the trigger is loop-safe"

grep -q 'local.confluence_publication_definition_arn,' "$reconciliation_file"
grep -q 'Resource = aws_iam_role.confluence_publication.arn' "$reconciliation_file"
grep -q 'action = "aws:executeAutomation"' "$repository_root/confluence.tf"
echo "PASS: both hint and scheduled candidates start independently retryable, readiness-gated publication"
