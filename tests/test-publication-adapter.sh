#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
publication_file="$repository_root/publication.tf"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

extract_script() {
  local name=$1
  awk -v name="$name" '
    $0 ~ "  " name " = .*<<-PYTHON" { capture = 1; next }
    capture && $0 == "  PYTHON" { exit }
    capture { sub(/^    /, ""); print }
  ' "$publication_file"
}

{
  extract_script derive_s3_publication_identity_script
  extract_script finalize_s3_publication_result_script
  cat <<'PYTHON'

identity = derive({
    "DestinationBucketName": "experiment-publication-abc123",
    "DnsSuffix": "amazonaws.com",
    "Region": "us-east-1",
    "SourceBucketName": "experiment-source-abc123",
    "SourceObjectKey": "users/a + b/100% ready.mp4",
    "SourceVersionId": "v+/= opaque",
}, None)
assert identity == {
    "CopySource": "experiment-source-abc123/users/a%20%2B%20b/100%25%20ready.mp4?versionId=v%2B%2F%3D%20opaque",
    "DestinationId": "users/a + b/100% ready.mp4",
    "DestinationKey": "users/a + b/100% ready.mp4",
    "MediaUrl": "https://experiment-publication-abc123.s3.us-east-1.amazonaws.com/users/a%20%2B%20b/100%25%20ready.mp4",
}

result = finalize({
    "DestinationBucketName": "experiment-publication-abc123",
    "DestinationETag": '"etag"',
    "DestinationId": identity["DestinationId"],
    "DestinationVersionId": "destination-version",
    "MediaUrl": identity["MediaUrl"],
}, None)
assert result["DestinationType"] == "s3"
assert result["DestinationId"] == identity["DestinationId"]
assert result["ConcurrencyToken"] == "destination-version"
assert result["DestinationDetails"]["ObjectKey"] == identity["DestinationKey"]
print("PASS: publication identity preserves literal keys and safely encodes S3 requests and links")
print("PASS: publication result implements the destination-independent contract")
PYTHON
} > "$temporary_directory/test_publication.py"

python3 "$temporary_directory/test_publication.py"

{
  cat <<'PYTHON'
import io
import sys
import types


class ClientError(Exception):
    def __init__(self, code):
        self.response = {"Error": {"Code": code}}


class FakeS3:
    def __init__(self, annotations, get_error=None, put_error_after=None):
        self.annotations = annotations
        self.get_error = get_error
        self.put_error_after = put_error_after
        self.puts = []

    def get_object_annotation(self, AnnotationName, **kwargs):
        if self.get_error is not None:
            raise ClientError(self.get_error)
        if AnnotationName not in self.annotations:
            raise ClientError("NoSuchAnnotation")
        return {"AnnotationPayload": io.BytesIO(
            self.annotations[AnnotationName].encode("utf-8"))}

    def put_object_annotation(self, AnnotationName, AnnotationPayload, **kwargs):
        if self.put_error_after is not None and len(self.puts) >= self.put_error_after:
            raise ClientError("AccessDenied")
        value = AnnotationPayload.decode("utf-8")
        self.annotations[AnnotationName] = value
        self.puts.append((AnnotationName, value, kwargs))


botocore = types.ModuleType("botocore")
botocore_exceptions = types.ModuleType("botocore.exceptions")
botocore_exceptions.ClientError = ClientError
botocore.exceptions = botocore_exceptions
sys.modules["botocore"] = botocore
sys.modules["botocore.exceptions"] = botocore_exceptions
boto3 = types.ModuleType("boto3")
sys.modules["boto3"] = boto3
PYTHON
  extract_script write_publication_annotations_script
  cat <<'PYTHON'

payload = {
    "ConcurrencyToken": "destination-version",
    "DestinationId": "users/a + b/100% ready.mp4",
    "DestinationType": "s3",
    "MediaUrl": "https://destination.example/users/a%20%2B%20b/100%25%20ready.mp4",
    "SourceBucketName": "experiment-source-abc123",
    "SourceETag": '"source-etag"',
    "SourceObjectKey": "users/a + b/100% ready.mp4",
    "SourceVersionId": "source-version",
}
expected = {
    "publication.destination": payload["DestinationType"],
    "publication.url": payload["MediaUrl"],
    "publication.id": payload["DestinationId"],
    "publication.concurrency-token": payload["ConcurrencyToken"],
}

client = FakeS3(expected.copy())
boto3.client = lambda service: client
assert write(payload, None) == {"ChangedAnnotationNames": []}
assert client.puts == []

state = expected.copy()
del state["publication.url"]
state["publication.concurrency-token"] = "stale-version"
client = FakeS3(state)
boto3.client = lambda service: client
result = write(payload, None)
assert result == {"ChangedAnnotationNames": [
    "publication.url", "publication.concurrency-token"]}
assert state == expected
assert all(call[2] == {
    "Bucket": payload["SourceBucketName"],
    "Key": payload["SourceObjectKey"],
    "VersionId": payload["SourceVersionId"],
    "ObjectIfMatch": payload["SourceETag"],
} for call in client.puts)

client = FakeS3({}, get_error="AccessDenied")
boto3.client = lambda service: client
try:
    write(payload, None)
except ClientError as error:
    assert error.response["Error"]["Code"] == "AccessDenied"
else:
    raise AssertionError("permission failure was treated as a missing annotation")
assert client.puts == []

state = {}
client = FakeS3(state, put_error_after=2)
boto3.client = lambda service: client
try:
    write(payload, None)
except ClientError as error:
    assert error.response["Error"]["Code"] == "AccessDenied"
else:
    raise AssertionError("partial write-back failure was hidden")
assert state == {
    "publication.destination": expected["publication.destination"],
    "publication.url": expected["publication.url"],
}

client = FakeS3(state)
boto3.client = lambda service: client
assert write(payload, None) == {"ChangedAnnotationNames": [
    "publication.id", "publication.concurrency-token"]}
assert state == expected
assert [call[0] for call in client.puts] == [
    "publication.id", "publication.concurrency-token"]
print("PASS: equivalent publication annotations are left unchanged")
print("PASS: missing and stale annotations are repaired against the pinned source version")
print("PASS: publication annotation permission failures remain visible and do not write state")
print("PASS: an independent retry repairs only state left incomplete by a partial write-back failure")
PYTHON
} > "$temporary_directory/test_publication_annotations.py"

python3 "$temporary_directory/test_publication_annotations.py"

for action in HeadObject CopyObject; do
  if ! grep -q "Api.*= \"$action\"" "$publication_file"; then
    echo "FAIL: publication adapter does not use native S3 $action" >&2
    exit 1
  fi
done

if ! grep -q 'ServerSideEncryption = "AES256"' "$publication_file"; then
  echo "FAIL: publication copy does not select SSE-S3 explicitly" >&2
  exit 1
fi

if ! grep -q 's3.put_object_annotation' "$publication_file"; then
  echo "FAIL: publication adapter does not write the version-bound result" >&2
  exit 1
fi

python3 - "$publication_file" <<'PYTHON'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
document = source[source.index('resource "aws_ssm_document" "publication_adapter"'):]
parameters = document[document.index("parameters = {"):document.index("variables = {")]
assert set(re.findall(r"^      ([A-Za-z][A-Za-z0-9]+) = \{$", parameters,
                      re.MULTILINE)) == {
    "SourceBucketName", "SourceObjectKey", "SourceVersionId"
}
for output in ("DestinationType", "MediaUrl", "DestinationId",
               "ConcurrencyToken", "DestinationDetails"):
    assert f'"finalizePublicationResult.{output}"' in document

policy = source[source.index('resource "aws_iam_role_policy" "publication_adapter"'):
                source.index('resource "aws_ssm_document" "publication_adapter"')]
actions = set(re.findall(r'"(s3:[A-Za-z]+)"', policy))
assert actions == {
    "s3:GetObject", "s3:GetObjectAnnotation", "s3:GetObjectVersion", "s3:GetObjectVersionAnnotation",
    "s3:PutObject", "s3:PutObjectAnnotation", "s3:PutObjectVersionAnnotation",
}
assert '${aws_s3_bucket.source.arn}/*' in policy
assert '${aws_s3_bucket.publication_adapter.arn}/*' in policy
assert 'Resource = "*"' not in policy
PYTHON

echo "PASS: publication reconciliation uses native S3 inspection and copy APIs"
echo "PASS: the constrained script boundary writes version-bound publication annotations"
echo "PASS: publication copy explicitly selects SSE-S3"
echo "PASS: Automation exposes only the minimal request and destination-neutral result"
echo "PASS: IAM is limited to required operations on the managed source and destination objects"
