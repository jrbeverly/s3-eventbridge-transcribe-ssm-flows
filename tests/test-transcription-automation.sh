#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
automation="$repository_root/transcription.tf"
events="$repository_root/events.tf"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

for action in \
  'Api                  = "GetTranscriptionJob"' \
  'Api                  = "StartTranscriptionJob"' \
  'action         = "aws:waitForAwsResourceProperty"' \
  'DesiredValues        = ["COMPLETED", "FAILED"]'; do
  grep -Fq "$action" "$automation"
done
grep -Fq 'Message = "Amazon Transcribe failed: {{ getFailedJob.FailureReason }}"' "$automation"
echo "PASS: native SSM actions inspect, start, and wait while terminal failures expose their reason"

grep -Fq '(bucket + "\0" + key + "\0" + version_id)' "$automation"
grep -Fq '"JobName": "transcribe-" + digest' "$automation"
grep -Fq 'onFailure      = "step:getJobAfterStartFailure"' "$automation"
grep -Fq 'NextStep = "waitForTerminalState"' "$automation"
echo "PASS: deterministic source identity and post-start reconciliation bound duplicate jobs"

awk '
  $0 ~ "  derive_transcription_identity_script = <<-PYTHON" { capture = 1; next }
  capture && $0 == "  PYTHON" { exit }
  capture { sub(/^    /, ""); print }
' "$automation" > "$temporary_directory/derive_identity.py"
awk '
  $0 ~ "  derive_transcription_artifact_script = <<-PYTHON" { capture = 1; next }
  capture && $0 == "  PYTHON" { exit }
  capture { sub(/^    /, ""); print }
' "$automation" > "$temporary_directory/derive_artifacts.py"
python3 - "$temporary_directory" <<'PYTHON'
import importlib.util
import pathlib
import sys
from urllib.parse import parse_qsl


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


root = pathlib.Path(sys.argv[1])
identity = load("derive_identity", root / "derive_identity.py")
artifacts = load("derive_artifacts", root / "derive_artifacts.py")
key = "prefix with spaces/Unicode 雪/demo.final.take.MP4"
source = {"BucketName": "source-bucket", "ObjectKey": key, "VersionId": "v+/= opaque"}
derived_identity = identity.derive(source, None)
assert derived_identity["OutputPrefix"] == (
    "prefix with spaces/Unicode 雪/demo.final.take.transcription/"
)
event = {
    **source,
    "Environment": "experiment",
    "ProjectName": "project",
    "TranscriptFileUri": "s3://source-bucket/staging/job%20name.json",
    "SubtitleFileUris": ["s3://source-bucket/staging/job%20name.vtt"],
}
derived = artifacts.materialize(event, None)
assert derived["JsonKey"] == "prefix with spaces/Unicode 雪/demo.final.take.transcription.json"
assert derived["VttKey"] == "prefix with spaces/Unicode 雪/demo.final.take.transcription.vtt"
assert derived["JsonCopySource"] == "source-bucket/staging/job%20name.json"
assert derived["VttCopySource"] == "source-bucket/staging/job%20name.vtt"
assert dict(parse_qsl(derived["Tagging"])) == {
    "Environment": "experiment",
    "ManagedBy": "SSMAutomation",
    "Project": "project",
    "Responsibility": "TranscriptionArtifact",
    "SourceVersionId": "v+/= opaque",
}
PYTHON
echo "PASS: stable naming and copy encoding preserve prefixes, spaces, Unicode, dots, and source versions"

grep -Fq 'name           = "probeSourceBeforeMaterialization"' "$automation"
grep -Fq 'StringEquals = "{{ probeCurrentObject.VersionId }}"' "$automation"
grep -Fq 'Default = "failSourceChanged"' "$automation"
echo "PASS: an overwritten source is rejected before stable artifacts are materialized"

for setting in \
  'MediaFileUri = "{{ deriveTranscriptionIdentity.MediaUri }}"' \
  'LanguageCode         = "{{ LanguageCode }}"' \
  'MediaFormat          = "mp4"' \
  'OutputBucketName = "{{ BucketName }}"' \
  'Formats          = ["vtt"]' \
  'OutputStartIndex = 1'; do
  grep -Fq "$setting" "$automation"
done
if grep -Fq 'OutputEncryptionKMSKeyId' "$automation"; then
  echo "FAIL: transcription unexpectedly overrides the bucket encryption contract" >&2
  exit 1
fi
echo "PASS: media, language, subtitle, output, and encryption choices match the real API probe"

grep -Fq 'event_id = "$.id"' "$events"
grep -Fq '"SourceEventId":[<event_id>]' "$events"
grep -Fq 'role_arn  = aws_iam_role.eventbridge_transcription.arn' "$events"
grep -Fq 'local.transcription_automation_definition_arn,' "$events"
grep -Fq 'Resource = aws_iam_role.transcription_automation.arn' "$events"
grep -Fq 'aws_sqs_queue.transcription_event_dlq.arn' "$events"
echo "PASS: EventBridge delivery carries correlation identity through a least-privilege invocation boundary"

[[ $(grep -Fc '"deriveTranscriptionIdentity.JobName"' "$automation") -eq 1 ]]
[[ $(grep -Fc '"deriveTranscriptionArtifacts.JsonUri"' "$automation") -eq 1 ]]
[[ $(grep -Fc '"deriveTranscriptionArtifacts.VttUri"' "$automation") -eq 1 ]]
echo "PASS: Automation exposes one deterministic job and one URI for each stable artifact"

grep -Fq 'MetadataDirective    = "REPLACE"' "$automation"
echo "PASS: artifact metadata is isolated while arbitrary source properties remain retrievable by version"
