#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${EVENT_FLOW_POLL_SECONDS:-10}
timeout_seconds=${EVENT_FLOW_TIMEOUT_SECONDS:-180}
settle_seconds=${EVENT_FLOW_SETTLE_SECONDS:-30}

if ! [[ $poll_seconds =~ ^[1-9][0-9]*$ &&
        $timeout_seconds =~ ^[1-9][0-9]*$ &&
        $settle_seconds =~ ^[0-9]+$ ]]; then
  echo "poll, timeout, and settle values must be whole seconds" >&2
  exit 2
fi

for command in aws jq terraform; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

source_bucket=${EVENT_FLOW_SOURCE_BUCKET:-$(terraform output -raw source_bucket_name)}
all_events_log_group=${EVENT_FLOW_ALL_EVENTS_LOG_GROUP:-$(terraform output -raw native_s3_event_observation_log_group_name)}
mp4_events_log_group=${EVENT_FLOW_MP4_EVENTS_LOG_GROUP:-$(terraform output -raw source_mp4_event_verification_log_group_name)}
automation_document=${EVENT_FLOW_AUTOMATION_DOCUMENT:-$(terraform output -raw object_probe_automation_document_name)}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
fixture_prefix="event-flow-verification/$run_id"
positive_key="$fixture_prefix/positive + 100%.mp4"
multipart_key="$fixture_prefix/multipart.mp4"
negative_key="$fixture_prefix/negative.txt"
temporary_directory=$(mktemp -d)
capture_start_ms=$(($(date +%s) * 1000))
capture_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cleanup() {
  for version_id in "${positive_v1:-}" "${positive_v2:-}"; do
    if [[ -n $version_id && $version_id != None ]]; then
      aws s3api delete-object \
        --bucket "$source_bucket" --key "$positive_key" --version-id "$version_id" \
        >/dev/null 2>&1 || true
    fi
  done
  if [[ -n ${multipart_v1:-} && ${multipart_v1:-} != None ]]; then
    aws s3api delete-object \
      --bucket "$source_bucket" --key "$multipart_key" --version-id "$multipart_v1" \
      >/dev/null 2>&1 || true
  elif [[ -n ${multipart_upload_id:-} && ${multipart_upload_id:-} != None ]]; then
    aws s3api abort-multipart-upload \
      --bucket "$source_bucket" --key "$multipart_key" --upload-id "$multipart_upload_id" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n ${negative_v1:-} && ${negative_v1:-} != None ]]; then
    aws s3api delete-object \
      --bucket "$source_bucket" --key "$negative_key" --version-id "$negative_v1" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

printf 'event-flow-positive-v1\n' > "$temporary_directory/positive-v1.mp4"
printf 'event-flow-negative\n' > "$temporary_directory/negative.txt"
printf 'event-flow-positive-v2\n' > "$temporary_directory/positive-v2.mp4"
printf 'event-flow-multipart\n' > "$temporary_directory/multipart.mp4"

put_fixture() {
  aws s3api put-object \
    --bucket "$source_bucket" \
    --key "$1" \
    --body "$2" \
    --query VersionId \
    --output text
}

positive_v1=$(put_fixture "$positive_key" "$temporary_directory/positive-v1.mp4")
negative_v1=$(put_fixture "$negative_key" "$temporary_directory/negative.txt")
positive_v2=$(put_fixture "$positive_key" "$temporary_directory/positive-v2.mp4")
multipart_upload_id=$(aws s3api create-multipart-upload \
  --bucket "$source_bucket" --key "$multipart_key" \
  --query UploadId --output text)
multipart_etag=$(aws s3api upload-part \
  --bucket "$source_bucket" --key "$multipart_key" \
  --upload-id "$multipart_upload_id" --part-number 1 \
  --body "$temporary_directory/multipart.mp4" \
  --query ETag --output text)
multipart_v1=$(aws s3api complete-multipart-upload \
  --bucket "$source_bucket" --key "$multipart_key" \
  --upload-id "$multipart_upload_id" \
  --multipart-upload "Parts=[{ETag=$multipart_etag,PartNumber=1}]" \
  --query VersionId --output text)

expected=$(jq -nc \
  --arg positive_key "$positive_key" \
  --arg positive_v1 "$positive_v1" \
  --arg positive_v2 "$positive_v2" \
  --arg negative_key "$negative_key" \
  --arg negative_v1 "$negative_v1" \
  --arg multipart_key "$multipart_key" \
  --arg multipart_v1 "$multipart_v1" \
  '[
    {key: $positive_key, version_id: $positive_v1},
    {key: $negative_key, version_id: $negative_v1},
    {key: $positive_key, version_id: $positive_v2},
    {key: $multipart_key, version_id: $multipart_v1}
  ]')

read_events() {
  aws logs filter-log-events \
    --log-group-name "$1" \
    --start-time "$capture_start_ms" \
    --query 'events[].message' \
    --output json | jq --arg prefix "$fixture_prefix/" \
      '[.[] | fromjson | select(.detail.object.key | startswith($prefix))]'
}

matches_fixture() {
  jq -e --arg key "$1" --arg version_id "$2" \
    'any(.[]; .detail.object.key == $key and .detail.object."version-id" == $version_id)' \
    >/dev/null <<< "$3"
}

read_automation_inputs() {
  local execution_ids
  local inputs='[]'

  execution_ids=$(aws ssm describe-automation-executions \
    --filters \
      "Key=DocumentNamePrefix,Values=$automation_document" \
      "Key=StartTimeAfter,Values=$capture_start" \
    --output json | jq -r --arg document "$automation_document" \
      '.AutomationExecutionMetadataList[] | select(.DocumentName == $document) | .AutomationExecutionId')
  for execution_id in $execution_ids; do
    inputs=$(aws ssm get-automation-execution \
      --automation-execution-id "$execution_id" \
      --query 'AutomationExecution.Parameters' \
      --output json | jq --argjson inputs "$inputs" '$inputs + [.]')
  done
  printf '%s\n' "$inputs"
}

matches_automation_input() {
  jq -e --arg bucket "$1" --arg key "$2" --arg version_id "$3" \
    'any(.[]; .BucketName == [$bucket] and .ObjectKey == [$key] and .VersionId == [$version_id])' \
    >/dev/null <<< "$4"
}

count_automation_inputs() {
  jq -r --arg bucket "$1" --arg key "$2" \
    '[.[] | select(.BucketName == [$bucket] and .ObjectKey == [$key])] | length' \
    <<< "$3"
}

deadline=$((SECONDS + timeout_seconds))
settle_deadline=0
while ((SECONDS < deadline || (settle_deadline > 0 && SECONDS < settle_deadline))); do
  all_events=$(read_events "$all_events_log_group")
  mp4_events=$(read_events "$mp4_events_log_group")
  automation_inputs=$(read_automation_inputs)

  positives_arrived=true
  while IFS=$'\t' read -r key version_id; do
    matches_fixture "$key" "$version_id" "$all_events" || positives_arrived=false
  done < <(jq -r '.[] | [.key, .version_id] | @tsv' <<< "$expected")
  for version_id in "$positive_v1" "$positive_v2"; do
    matches_fixture "$positive_key" "$version_id" "$mp4_events" || positives_arrived=false
  done
  matches_fixture "$multipart_key" "$multipart_v1" "$mp4_events" || positives_arrived=false
  matches_automation_input "$source_bucket" "$positive_key" "$positive_v1" "$automation_inputs" || positives_arrived=false
  matches_automation_input "$source_bucket" "$positive_key" "$positive_v2" "$automation_inputs" || positives_arrived=false
  matches_automation_input "$source_bucket" "$multipart_key" "$multipart_v1" "$automation_inputs" || positives_arrived=false

  if $positives_arrived && ((settle_deadline == 0)); then
    settle_deadline=$((SECONDS + settle_seconds))
  fi
  if ((settle_deadline > 0 && SECONDS >= settle_deadline)); then
    break
  fi
  sleep "$poll_seconds"
done

failed=false
while IFS=$'\t' read -r key version_id; do
  if ! matches_fixture "$key" "$version_id" "$all_events"; then
    echo "FAIL: all-events target did not receive $key version $version_id" >&2
    failed=true
  fi
done < <(jq -r '.[] | [.key, .version_id] | @tsv' <<< "$expected")

for version_id in "$positive_v1" "$positive_v2"; do
  if ! matches_fixture "$positive_key" "$version_id" "$mp4_events"; then
    echo "FAIL: MP4 target did not receive $positive_key version $version_id" >&2
    failed=true
  fi
done
if ! matches_fixture "$multipart_key" "$multipart_v1" "$mp4_events"; then
  echo "FAIL: MP4 target did not receive multipart completion $multipart_key version $multipart_v1" >&2
  failed=true
elif jq -e --arg key "$multipart_key" --arg version_id "$multipart_v1" '
  any(.[]; .detail.object.key == $key and
           .detail.object."version-id" == $version_id and
           .detail.reason == "CompleteMultipartUpload")
' >/dev/null <<< "$mp4_events"; then
  echo "PASS: multipart upload produced a CompleteMultipartUpload event"
else
  echo "FAIL: multipart event did not report CompleteMultipartUpload" >&2
  failed=true
fi

if matches_fixture "$negative_key" "$negative_v1" "$mp4_events"; then
  echo "FAIL: MP4 target received negative fixture $negative_key" >&2
  failed=true
else
  echo "PASS: MP4 target excluded $negative_key after bounded polling"
fi

if jq -e --arg bucket "$source_bucket" --arg key "$negative_key" \
  'any(.[]; .BucketName == [$bucket] and .ObjectKey == [$key])' \
  >/dev/null <<< "$automation_inputs"; then
  echo "FAIL: ineligible fixture started an Automation for $negative_key" >&2
  failed=true
else
  echo "PASS: ineligible fixture did not start an Automation"
fi

automation_delivery_count=$(count_automation_inputs "$source_bucket" "$positive_key" "$automation_inputs")
multipart_automation_delivery_count=$(count_automation_inputs "$source_bucket" "$multipart_key" "$automation_inputs")
correlated_execution_count=0
for version_id in "$positive_v1" "$positive_v2"; do
  if matches_automation_input "$source_bucket" "$positive_key" "$version_id" "$automation_inputs"; then
    echo "PASS: source version $version_id correlates to an Automation execution parameter"
    ((correlated_execution_count += 1))
  else
    echo "FAIL: source version $version_id has no correlated Automation execution" >&2
    failed=true
  fi
done
if matches_automation_input "$source_bucket" "$multipart_key" "$multipart_v1" "$automation_inputs"; then
  echo "PASS: multipart source version $multipart_v1 correlates to an Automation execution parameter"
  ((correlated_execution_count += 1))
else
  echo "FAIL: multipart source version $multipart_v1 has no correlated Automation execution" >&2
  failed=true
fi

if ((automation_delivery_count >= 2 && multipart_automation_delivery_count >= 1 && correlated_execution_count == 3)); then
  echo "PASS: object probe received literal bucket, key, and exact version parameters for puts, overwrite, and multipart completion (executions: $((automation_delivery_count + multipart_automation_delivery_count)))"
else
  echo "FAIL: object probe received $automation_delivery_count put executions, $multipart_automation_delivery_count multipart executions, and $correlated_execution_count exact version identities; expected at least 2, 1, and 3" >&2
  failed=true
fi

summarize() {
  jq -r --arg target "$1" '
    group_by([
      .detail.object.key,
      .detail.object."version-id",
      .detail.object.sequencer,
      .detail.reason
    ])
    | .[]
    | "PASS: \($target) received \(.[0].detail.object.key) version \(.[0].detail.object["version-id"]) (deliveries: \(length))"
  ' <<< "$2"
}

summarize "all-events target" "$all_events"
summarize "MP4 target" "$mp4_events"

if $failed; then
  exit 1
fi
