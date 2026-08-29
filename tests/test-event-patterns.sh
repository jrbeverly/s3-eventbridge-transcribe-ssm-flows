#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

source_bucket=source-bucket
destination_bucket=destination-bucket
pattern_file="$temporary_directory/source-mp4-created.json"
sed 's/${source_bucket_name}/"'"$source_bucket"'"/' \
  "$repository_root/event-patterns/source-mp4-created.json.tftpl" > "$pattern_file"
expected_source=$(jq -er '.source | select(length == 1) | .[0]' "$pattern_file")
expected_detail_type=$(jq -er '."detail-type" | select(length == 1) | .[0]' "$pattern_file")
expected_bucket=$(jq -er '.detail.bucket.name | select(length == 1) | .[0]' "$pattern_file")
expected_suffix=$(jq -er '.detail.object.key | select(length == 1) | .[0].suffix."equals-ignore-case"' "$pattern_file")

test_event() {
  local description=$1
  local expected=$2
  local bucket=$3
  local detail_type=$4
  local key=${5-}
  local reason=${6-PutObject}
  local event_file="$temporary_directory/event.json"
  local actual

  jq -n \
    --arg bucket "$bucket" \
    --arg detail_type "$detail_type" \
    --arg key "$key" \
    --arg reason "$reason" \
    '{
      version: "0",
      id: "00000000-0000-0000-0000-000000000000",
      source: "aws.s3",
      account: "111122223333",
      time: "2026-01-01T00:00:00Z",
      region: "us-east-1",
      resources: [("arn:aws:s3:::" + $bucket)],
      "detail-type": $detail_type,
      detail: {
        bucket: {name: $bucket},
        object: {key: $key},
        reason: $reason
      }
    }' > "$event_file"

  if [[ -z $key ]]; then
    jq 'del(.detail.object.key)' "$event_file" > "$event_file.without-key"
    mv "$event_file.without-key" "$event_file"
  fi

  if [[ ${EVENT_PATTERN_TEST_LIVE_AWS:-0} == 1 ]]; then
    actual=$(aws events test-event-pattern \
      --event-pattern "file://$pattern_file" \
      --event "file://$event_file" \
      --query Result --output text | tr '[:upper:]' '[:lower:]')
  else
    actual=false
    if [[ aws.s3 == "$expected_source" &&
          $detail_type == "$expected_detail_type" &&
          $bucket == "$expected_bucket" &&
          -n $key &&
          ${key,,} == *"${expected_suffix,,}" ]]; then
      actual=true
    fi
  fi

  if [[ $actual != "$expected" ]]; then
    echo "FAIL: $description (expected $expected, received $actual)" >&2
    return 1
  fi
  echo "PASS: $description"
}

test_event "root MP4" true "$source_bucket" "Object Created" "recording.mp4"
test_event "arbitrary prefix and literal special characters" true "$source_bucket" "Object Created" "users/a + b/100% ready.mp4"
test_event "mixed-case MP4 suffix" true "$source_bucket" "Object Created" "users/a/recording.Mp4"
test_event "percent-encoded characters before the suffix" true "$source_bucket" "Object Created" "users/a/space%20name.mp4"
test_event "overwrite" true "$source_bucket" "Object Created" "users/a/recording.mp4" "PutObject"
test_event "multipart completion" true "$source_bucket" "Object Created" "users/a/recording.mp4" "CompleteMultipartUpload"
test_event "transcription VTT artifact" false "$source_bucket" "Object Created" "users/a/recording.transcription.vtt"
test_event "transcription JSON artifact" false "$source_bucket" "Object Created" "users/a/recording.transcription.json"
test_event "destination MP4" false "$destination_bucket" "Object Created" "users/a/recording.mp4"
test_event "annotation write-back" false "$source_bucket" "Object Annotation Created" "users/a/recording.mp4" "PutObjectAnnotation"
test_event "tag write-back" false "$source_bucket" "Object Tags Added" "users/a/recording.mp4" "PutObjectTagging"
test_event "non-MP4 object" false "$source_bucket" "Object Created" "users/a/recording.mov"
test_event "encoded extension separator" false "$source_bucket" "Object Created" "users/a/recording%2Emp4"
test_event "event without an object key" false "$source_bucket" "Object Created" ""
