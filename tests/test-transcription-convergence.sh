#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${TRANSCRIPTION_TEST_POLL_SECONDS:-15}
timeout_seconds=${TRANSCRIPTION_TEST_TIMEOUT_SECONDS:-1500}
settle_seconds=${TRANSCRIPTION_TEST_SETTLE_SECONDS:-30}
media_file=${TRANSCRIPTION_TEST_MEDIA_FILE:-}

if [[ -z $media_file || ! -f $media_file ]]; then
  echo "set TRANSCRIPTION_TEST_MEDIA_FILE to a short, valid English MP4" >&2
  exit 2
fi
if ! [[ $poll_seconds =~ ^[1-9][0-9]*$ &&
        $timeout_seconds =~ ^[1-9][0-9]*$ &&
        $settle_seconds =~ ^[0-9]+$ ]]; then
  echo "poll, timeout, and settle values must be whole seconds" >&2
  exit 2
fi
for command in aws jq terraform sha256sum; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

source_bucket=${TRANSCRIPTION_TEST_SOURCE_BUCKET:-$(terraform output -raw source_bucket_name)}
automation_document=${TRANSCRIPTION_TEST_AUTOMATION_DOCUMENT:-$(terraform output -raw transcription_automation_document_name)}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
fixture_prefix="transcription-convergence/$run_id"
source_key="$fixture_prefix/complete.mp4"
failed_key="$fixture_prefix/failed.mp4"
json_key="$fixture_prefix/complete.transcription.json"
vtt_key="$fixture_prefix/complete.transcription.vtt"
failed_json_key="$fixture_prefix/failed.transcription.json"
failed_vtt_key="$fixture_prefix/failed.transcription.vtt"
temporary_directory=$(mktemp -d)

cleanup() {
  versions=$(aws s3api list-object-versions \
    --bucket "$source_bucket" --prefix "$fixture_prefix/" --output json 2>/dev/null |
    jq -c '[((.Versions // []) + (.DeleteMarkers // []))[] | {Key, VersionId}]') || true
  if [[ -n ${versions:-} && $versions != '[]' ]]; then
    aws s3api delete-objects --bucket "$source_bucket" \
      --delete "$(jq -nc --argjson objects "$versions" '{Objects: $objects, Quiet: true}')" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

job_name() {
  printf '%s\0%s\0%s' "$source_bucket" "$1" "$2" |
    sha256sum | awk '{print "transcribe-" $1}'
}

start_execution() {
  aws ssm start-automation-execution \
    --document-name "$automation_document" \
    --parameters "BucketName=$source_bucket,ObjectKey=$1,SourceEventId=matrix-$run_id-$2" \
    --query AutomationExecutionId --output text
}

wait_execution() {
  local execution_id=$1
  local expected=$2
  local deadline=$((SECONDS + timeout_seconds))
  local status
  while ((SECONDS < deadline)); do
    status=$(aws ssm get-automation-execution --automation-execution-id "$execution_id" \
      --query 'AutomationExecution.AutomationExecutionStatus' --output text)
    case $status in
      Success|Failed|Cancelled|TimedOut)
        if [[ $status != "$expected" ]]; then
          echo "execution $execution_id ended as $status; expected $expected" >&2
          return 1
        fi
        return
        ;;
    esac
    sleep "$poll_seconds"
  done
  echo "execution $execution_id did not finish within $timeout_seconds seconds" >&2
  return 1
}

head_artifact() {
  aws s3api head-object --bucket "$source_bucket" --key "$1" --output json |
    jq '{version_id: .VersionId, content_type: .ContentType,
         source_version_id: .Metadata.sourceversionid}'
}

snapshot() {
  local label=$1
  local source_version=$2
  local job=$3
  local output="$temporary_directory/$label.json"
  jq -n \
    --arg label "$label" \
    --arg source_version "$source_version" \
    --argjson job "$(aws transcribe get-transcription-job --transcription-job-name "$job" --output json)" \
    --argjson json "$(head_artifact "$json_key")" \
    --argjson vtt "$(head_artifact "$vtt_key")" \
    --argjson versions "$(aws s3api list-object-versions --bucket "$source_bucket" \
      --prefix "$fixture_prefix/complete.transcription." --output json)" \
    '{label: $label, source_version: $source_version,
      job: {name: $job.TranscriptionJob.TranscriptionJobName,
            status: $job.TranscriptionJob.TranscriptionJobStatus},
      artifacts: {json: $json, vtt: $vtt},
      artifact_version_count: (($versions.Versions // []) | length)}' > "$output"
  jq . "$output"
}

assert_artifact_source() {
  local key=$1
  local source_version=$2
  local actual
  actual=$(head_artifact "$key" | jq -r .source_version_id)
  [[ $actual == "$source_version" ]] || {
    echo "$key identifies source version $actual; expected $source_version" >&2
    return 1
  }
}

delete_current() {
  aws s3api delete-object --bucket "$source_bucket" --key "$1" >/dev/null
}

remove_latest_delete_marker() {
  local key=$1
  local marker
  marker=$(aws s3api list-object-versions --bucket "$source_bucket" --prefix "$key" \
    --output json | jq -er --arg key "$key" \
      '.DeleteMarkers[] | select(.Key == $key and .IsLatest) | .VersionId')
  aws s3api delete-object --bucket "$source_bucket" --key "$key" \
    --version-id "$marker" >/dev/null
}

source_v1=$(aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$media_file" --query VersionId --output text)
job_v1=$(job_name "$source_key" "$source_v1")
initial_execution=$(start_execution "$source_key" initial)
wait_execution "$initial_execution" Success
sleep "$settle_seconds"
snapshot complete-before-rerun "$source_v1" "$job_v1"

json_v1=$(head_artifact "$json_key" | jq -r .version_id)
vtt_v1=$(head_artifact "$vtt_key" | jq -r .version_id)
rerun_execution=$(start_execution "$source_key" rerun)
wait_execution "$rerun_execution" Success
snapshot complete-after-rerun "$source_v1" "$job_v1"
[[ $(head_artifact "$json_key" | jq -r .version_id) == "$json_v1" ]]
[[ $(head_artifact "$vtt_key" | jq -r .version_id) == "$vtt_v1" ]]
echo "PASS: a manual rerun reused the job and did not create artifact versions"

delete_current "$vtt_key"
missing_vtt_execution=$(start_execution "$source_key" missing-vtt)
wait_execution "$missing_vtt_execution" Success
[[ $(head_artifact "$json_key" | jq -r .version_id) == "$json_v1" ]]
assert_artifact_source "$vtt_key" "$source_v1"
echo "PASS: a missing VTT was restored without replacing valid JSON"

vtt_after_vtt_recovery=$(head_artifact "$vtt_key" | jq -r .version_id)
delete_current "$json_key"
missing_json_execution=$(start_execution "$source_key" missing-json)
wait_execution "$missing_json_execution" Success
assert_artifact_source "$json_key" "$source_v1"
[[ $(head_artifact "$vtt_key" | jq -r .version_id) == "$vtt_after_vtt_recovery" ]]
echo "PASS: a missing JSON artifact was restored without replacing valid VTT"

subtitle_uri=$(aws transcribe get-transcription-job --transcription-job-name "$job_v1" \
  --query 'TranscriptionJob.Subtitles.SubtitleFileUris[0]' --output text)
staging_vtt_key=${subtitle_uri#s3://$source_bucket/}
delete_current "$staging_vtt_key"
delete_current "$vtt_key"
json_before_failure=$(head_artifact "$json_key" | jq -r .version_id)
downstream_failure_execution=$(start_execution "$source_key" downstream-failure)
wait_execution "$downstream_failure_execution" Failed
[[ $(head_artifact "$json_key" | jq -r .version_id) == "$json_before_failure" ]]
echo "PASS: valid JSON survived a failed VTT rematerialization"
remove_latest_delete_marker "$staging_vtt_key"
recovery_execution=$(start_execution "$source_key" downstream-recovery)
wait_execution "$recovery_execution" Success
assert_artifact_source "$vtt_key" "$source_v1"

printf 'not an mp4\n' > "$temporary_directory/failed.mp4"
failed_version=$(aws s3api put-object --bucket "$source_bucket" --key "$failed_key" \
  --body "$temporary_directory/failed.mp4" --query VersionId --output text)
failed_job=$(job_name "$failed_key" "$failed_version")
failed_execution=$(start_execution "$failed_key" failed-job)
wait_execution "$failed_execution" Failed
failed_rerun_execution=$(start_execution "$failed_key" failed-job-rerun)
wait_execution "$failed_rerun_execution" Failed
[[ $(aws transcribe get-transcription-job --transcription-job-name "$failed_job" \
  --query 'TranscriptionJob.TranscriptionJobStatus' --output text) == FAILED ]]
if aws s3api head-object --bucket "$source_bucket" --key "$failed_json_key" >/dev/null 2>&1 ||
   aws s3api head-object --bucket "$source_bucket" --key "$failed_vtt_key" >/dev/null 2>&1; then
  echo "failed deterministic job unexpectedly produced stable artifacts" >&2
  exit 1
fi
echo "PASS: a failed job remained terminal on rerun and produced no stable artifacts"

source_v2=$(aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$media_file" --query VersionId --output text)
job_v2=$(job_name "$source_key" "$source_v2")
[[ $job_v2 != "$job_v1" ]]
overwrite_execution=$(start_execution "$source_key" overwrite)
wait_execution "$overwrite_execution" Success
assert_artifact_source "$json_key" "$source_v2"
assert_artifact_source "$vtt_key" "$source_v2"
snapshot overwrite-after "$source_v2" "$job_v2"
[[ $(aws transcribe get-transcription-job --transcription-job-name "$job_v1" \
  --query 'TranscriptionJob.TranscriptionJobStatus' --output text) == COMPLETED ]]
echo "PASS: overwrite created one new deterministic job and converged stable artifacts to the new source version"
