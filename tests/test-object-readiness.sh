#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readiness_file="$repository_root/readiness.tf"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

extract_script() {
  local name=$1
  awk -v name="$name" '
    $0 ~ "  " name " = .*<<-PYTHON" { capture = 1; next }
    capture && $0 == "  PYTHON" { exit }
    capture { sub(/^    /, ""); print }
  ' "$readiness_file"
}

{
  cat <<'PYTHON'
import io
import sys
import types


class ClientError(Exception):
    def __init__(self, code):
        self.response = {"Error": {"Code": code}}


class FakeS3:
    def __init__(self, complete=True):
        self.complete = complete
        self.vtt_body = b"WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n"
        self.vtt_source_version = "source-version"
        self.annotations = {
            "publication.destination": "s3",
            "publication.id": "path/recording.mp4",
            "publication.url": "https://destination.example/path/recording.mp4",
            "publication.concurrency-token": "destination-version",
        }

    def head_object(self, Bucket, Key, VersionId=None, IfMatch=None):
        if Key == "missing.mp4":
            raise ClientError("NoSuchKey")
        if Bucket == "source-bucket" and Key == "path/recording.mp4":
            return {
                "VersionId": "source-version",
                "ETag": '"same-etag"',
                "ContentType": "video/mp4",
                "ContentLength": 123,
                "Metadata": {"system": "alpha", "participants": "a,b"},
            }
        if Bucket == "source-bucket" and Key == "path/recording.transcription.vtt":
            if not self.complete:
                raise ClientError("NoSuchKey")
            return {
                "VersionId": "vtt-version",
                "ETag": '"vtt-etag"',
                "ContentType": "text/vtt; charset=utf-8",
                "ContentLength": 42,
                "Metadata": {"sourceversionid": self.vtt_source_version},
            }
        if Bucket == "destination-bucket" and Key == "path/recording.mp4":
            return {"VersionId": VersionId, "ETag": '"same-etag"', "ContentLength": 123}
        raise AssertionError((Bucket, Key, VersionId, IfMatch))

    def get_object_annotation(self, AnnotationName, **kwargs):
        if not self.complete or AnnotationName not in self.annotations:
            raise ClientError("NoSuchAnnotation")
        return {"AnnotationPayload": io.BytesIO(self.annotations[AnnotationName].encode())}

    def get_object(self, Bucket, Key, VersionId):
        assert (Bucket, Key, VersionId) == (
            "source-bucket", "path/recording.transcription.vtt", "vtt-version")
        return {"Body": io.BytesIO(self.vtt_body)}


botocore = types.ModuleType("botocore")
botocore_exceptions = types.ModuleType("botocore.exceptions")
botocore_exceptions.ClientError = ClientError
botocore.exceptions = botocore_exceptions
sys.modules["botocore"] = botocore
sys.modules["botocore.exceptions"] = botocore_exceptions
boto3 = types.ModuleType("boto3")
sys.modules["boto3"] = boto3
PYTHON
  extract_script evaluate_object_readiness_script
  cat <<'PYTHON'

payload = {
    "SourceBucketName": "source-bucket",
    "SourceObjectKey": "path/recording.mp4",
    "PublicationBucketName": "destination-bucket",
}

client = FakeS3(complete=True)
boto3.client = lambda service: client
result = evaluate(payload, None)
assert result["Ready"] is True
assert result["NotReadyReasons"] == []
assert result["SourceIdentity"]["VersionId"] == "source-version"
assert result["SourceProperties"] == {"system": "alpha", "participants": "a,b"}
assert result["VttLocation"]["ObjectKey"] == "path/recording.transcription.vtt"
assert result["VttLocation"]["VersionId"] == "vtt-version"
assert result["DestinationFacts"]["DestinationType"] == "s3"
assert result["DestinationFacts"]["ConcurrencyToken"] == "destination-version"
assert result["DestinationFacts"]["BucketName"] == "destination-bucket"
print("PASS: complete state returns a structured ready result and publisher inputs")

client = FakeS3(complete=False)
boto3.client = lambda service: client
result = evaluate(payload, None)
assert result["Ready"] is False
assert result["SourceProperties"] == {"system": "alpha", "participants": "a,b"}
assert result["NotReadyReasons"] == [
    "VTT_MISSING",
    "PUBLICATION_DESTINATION_MISSING",
    "PUBLICATION_ID_MISSING",
    "PUBLICATION_URL_MISSING",
]
print("PASS: incomplete state returns every independently observable reason")

client = FakeS3()
client.vtt_body = b"this is readable UTF-8 but not WEBVTT\n"
boto3.client = lambda service: client
malformed = evaluate(payload, None)
assert malformed["Ready"] is False
assert malformed["NotReadyReasons"] == ["VTT_MALFORMED"]

client = FakeS3()
client.vtt_source_version = "older-source-version"
boto3.client = lambda service: client
stale = evaluate(payload, None)
assert stale["Ready"] is False
assert stale["NotReadyReasons"] == ["VTT_STALE"]
print("PASS: malformed and stale VTT facts return explicit not-ready reasons")

boto3.client = lambda service: FakeS3()
missing = evaluate({**payload, "SourceObjectKey": "missing.mp4"}, None)
assert missing["Ready"] is False
assert missing["NotReadyReasons"] == ["SOURCE_MISSING"]
assert missing["SourceIdentity"] == {
    "BucketName": "source-bucket", "ObjectKey": "missing.mp4"}
print("PASS: a missing source is a successful not-ready evaluation")
PYTHON
} > "$temporary_directory/test_readiness.py"

python3 "$temporary_directory/test_readiness.py"

for action in 'action         = "aws:executeAwsApi"' 'action = "aws:branch"'; do
  if ! grep -q "$action" "$readiness_file"; then
    echo "FAIL: readiness Automation does not attempt native API and branch actions first" >&2
    exit 1
  fi
done

if grep -Eq 'StartTranscriptionJob|CopyObject|PutObject|start_.*transcription|copy_object|put_object' "$readiness_file"; then
  echo "FAIL: readiness Automation contains a transcription or publication mutation" >&2
  exit 1
fi

echo "PASS: readiness Automation attempts native inspection and branching before its predicate script"
echo "PASS: readiness Automation is read-only"
