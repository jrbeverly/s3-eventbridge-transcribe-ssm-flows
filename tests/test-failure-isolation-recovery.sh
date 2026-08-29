#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${FAILURE_TEST_POLL_SECONDS:-15}
timeout_seconds=${FAILURE_TEST_TIMEOUT_SECONDS:-1800}
iam_settle_seconds=${FAILURE_TEST_IAM_SETTLE_SECONDS:-10}
media_file=${FAILURE_TEST_MEDIA_FILE:-}

if [[ -z $media_file || ! -f $media_file ]]; then
  echo "set FAILURE_TEST_MEDIA_FILE to a short, valid English MP4" >&2
  exit 2
fi
if ! [[ $poll_seconds =~ ^[1-9][0-9]*$ &&
        $timeout_seconds =~ ^[1-9][0-9]*$ &&
        $iam_settle_seconds =~ ^[0-9]+$ ]]; then
  echo "poll, timeout, and IAM settle values must be whole seconds" >&2
  exit 2
fi
for command in aws curl jq python3 sha256sum terraform; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TRANSCRIPTION_TEST_MEDIA_FILE="$media_file" \
  TRANSCRIPTION_TEST_POLL_SECONDS="$poll_seconds" \
  TRANSCRIPTION_TEST_TIMEOUT_SECONDS="$timeout_seconds" \
  bash "$repository_root/tests/test-transcription-convergence.sh"
PUBLICATION_TEST_POLL_SECONDS="$poll_seconds" \
  PUBLICATION_TEST_TIMEOUT_SECONDS="$timeout_seconds" \
  PUBLICATION_TEST_IAM_SETTLE_SECONDS="$iam_settle_seconds" \
  bash "$repository_root/tests/test-publication-convergence.sh"

source_bucket=$(terraform output -raw source_bucket_name)
destination_bucket=$(terraform output -json publication_adapter | jq -er .target)
transcription_document=$(terraform output -raw transcription_automation_document_name)
publication_document=$(terraform output -raw publication_adapter_automation_document_name)
confluence_document=$(terraform output -raw confluence_publication_automation_document_name)
confluence_role_arn=$(terraform output -raw confluence_publication_automation_role_arn)
readiness=$(terraform output -json readiness_reconciliation)
readiness_document=$(jq -er .automation_document_name <<< "$readiness")
hint_rule=$(jq -er .event_rule_name <<< "$readiness")
schedule_rule=$(jq -er .schedule_rule_name <<< "$readiness")
interval_minutes=$(jq -er .interval_minutes <<< "$readiness")

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
fixture_prefix="failure-isolation/$run_id"
source_key="$fixture_prefix/representative.mp4"
json_key="$fixture_prefix/representative.transcription.json"
vtt_key="$fixture_prefix/representative.transcription.vtt"
temporary_directory=$(mktemp -d)
automation_role_name=${confluence_role_arn##*/}
deny_policy_name="failure-test-deny-readiness-$run_id"
deny_policy_installed=false
rules_disabled=false
page_id=

document=$(aws ssm get-document --name "$confluence_document" \
  --document-version '$DEFAULT' --query Content --output text | jq -e .)
confluence_base_url=$(jq -er \
  '.mainSteps[] | select(.name == "publish").inputs.InputPayload.ConfluenceBaseUrl' \
  <<< "$document")
credentials_secret_arn=$(jq -er \
  '.mainSteps[] | select(.name == "publish").inputs.InputPayload.CredentialsSecretArn' \
  <<< "$document")
credentials=$(aws secretsmanager get-secret-value --secret-id "$credentials_secret_arn" \
  --query SecretString --output text)
confluence_email=$(jq -er .email <<< "$credentials")
confluence_token=$(jq -er .api_token <<< "$credentials")
unset credentials
confluence_host=$(python3 - "$confluence_base_url" <<'PYTHON'
from urllib.parse import urlparse
import sys
parsed = urlparse(sys.argv[1])
if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".atlassian.net"):
    raise SystemExit("Confluence base URL must be an https://*.atlassian.net origin")
print(parsed.hostname)
PYTHON
)
netrc_file="$temporary_directory/confluence.netrc"
printf 'machine %s login %s password %s\n' \
  "$confluence_host" "$confluence_email" "$confluence_token" > "$netrc_file"
chmod 600 "$netrc_file"
unset confluence_email confluence_token

confluence_call() {
  curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
    --netrc-file "$netrc_file" --header 'Accept: application/json' \
    --request "$1" --output "${3:-/dev/stdout}" "$confluence_base_url$2"
}

source_marker() {
  python3 - "$source_bucket" "$source_key" <<'PYTHON'
import hashlib
import sys
print("source-" + hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:32])
PYTHON
}

find_page_id() {
  local marker
  marker=$(source_marker)
  confluence_call GET \
    "/wiki/rest/api/content/search?cql=type%3Dpage%20and%20label%3D%22$marker%22&limit=2" |
    jq -er 'if (.results | length) == 1 then .results[0].id else empty end' 2>/dev/null
}

cleanup() {
  local versions found_page
  if $deny_policy_installed; then
    aws iam delete-role-policy --role-name "$automation_role_name" \
      --policy-name "$deny_policy_name" >/dev/null 2>&1 || true
  fi
  if $rules_disabled; then
    aws events enable-rule --name "$hint_rule" >/dev/null 2>&1 || true
    aws events enable-rule --name "$schedule_rule" >/dev/null 2>&1 || true
  fi
  found_page=${page_id:-$(find_page_id 2>/dev/null || true)}
  if [[ -n $found_page ]]; then
    confluence_call DELETE "/wiki/api/v2/pages/$found_page" /dev/null >/dev/null 2>&1 || true
  fi
  for bucket in "$source_bucket" "$destination_bucket"; do
    versions=$(aws s3api list-object-versions --bucket "$bucket" --prefix "$fixture_prefix/" \
      --output json 2>/dev/null | jq -c \
      '[((.Versions // []) + (.DeleteMarkers // []))[] | {Key, VersionId}]') || true
    if [[ -n ${versions:-} && $versions != '[]' ]]; then
      aws s3api delete-objects --bucket "$bucket" \
        --delete "$(jq -nc --argjson objects "$versions" '{Objects: $objects, Quiet: true}')" \
        >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

start_execution() {
  local document_name=$1 parameters=$2
  aws ssm start-automation-execution --document-name "$document_name" \
    --parameters "$parameters" --query AutomationExecutionId --output text
}

wait_execution() {
  local execution_id=$1 expected=$2 deadline=$((SECONDS + timeout_seconds)) response status
  while ((SECONDS < deadline)); do
    response=$(aws ssm get-automation-execution \
      --automation-execution-id "$execution_id" --output json)
    status=$(jq -r '.AutomationExecution.AutomationExecutionStatus' <<< "$response")
    case $status in
      Success|Failed|Cancelled|TimedOut)
        if [[ $status != "$expected" ]]; then
          jq '.AutomationExecution | {AutomationExecutionId, DocumentName,
            AutomationExecutionStatus, FailureMessage, StepExecutions}' <<< "$response" >&2
          return 1
        fi
        printf '%s\n' "$response"
        return
        ;;
    esac
    sleep "$poll_seconds"
  done
  echo "execution $execution_id did not finish within $timeout_seconds seconds" >&2
  return 1
}

version_count() {
  aws s3api list-object-versions --bucket "$1" --prefix "$2" --output json |
    jq -r --arg key "$2" '[.Versions[]? | select(.Key == $key)] | length'
}

annotation_value() {
  local name=$1 output="$temporary_directory/annotation-$RANDOM"
  aws s3api get-object-annotation --bucket "$source_bucket" --key "$source_key" \
    --version-id "$source_version" --annotation-name "$name" "$output" >/dev/null
  tr -d '\r\n' < "$output"
  rm -f "$output"
}

job_name() {
  printf '%s\0%s\0%s' "$source_bucket" "$source_key" "$source_version" |
    sha256sum | awk '{print "transcribe-" $1}'
}

upstream_snapshot() {
  jq -nc \
    --arg source_version "$(aws s3api head-object --bucket "$source_bucket" \
      --key "$source_key" --query VersionId --output text)" \
    --arg job_status "$(aws transcribe get-transcription-job \
      --transcription-job-name "$(job_name)" \
      --query 'TranscriptionJob.TranscriptionJobStatus' --output text)" \
    --arg json_version "$(aws s3api head-object --bucket "$source_bucket" \
      --key "$json_key" --query VersionId --output text)" \
    --arg vtt_version "$(aws s3api head-object --bucket "$source_bucket" \
      --key "$vtt_key" --query VersionId --output text)" \
    --arg destination_version "$(aws s3api head-object --bucket "$destination_bucket" \
      --key "$source_key" --query VersionId --output text)" \
    --arg publication_destination "$(annotation_value publication.destination)" \
    --arg publication_id "$(annotation_value publication.id)" \
    --arg publication_url "$(annotation_value publication.url)" \
    --arg publication_token "$(annotation_value publication.concurrency-token)" \
    --argjson json_count "$(version_count "$source_bucket" "$json_key")" \
    --argjson vtt_count "$(version_count "$source_bucket" "$vtt_key")" \
    --argjson destination_count "$(version_count "$destination_bucket" "$source_key")" \
    '{source_version: $source_version, job_status: $job_status,
      json_version: $json_version, vtt_version: $vtt_version,
      destination_version: $destination_version,
      annotations: {destination: $publication_destination, id: $publication_id,
        url: $publication_url, concurrency_token: $publication_token},
      json_count: $json_count, vtt_count: $vtt_count,
      destination_count: $destination_count}'
}

assert_upstream_unchanged() {
  local actual
  actual=$(upstream_snapshot)
  if [[ $actual != "$upstream_baseline" ]]; then
    echo "upstream state changed across downstream failure or recovery" >&2
    jq -n --argjson expected "$upstream_baseline" --argjson actual "$actual" \
      '{expected: $expected, actual: $actual}' >&2
    return 1
  fi
}

aws events disable-rule --name "$hint_rule"
aws events disable-rule --name "$schedule_rule"
rules_disabled=true

source_version=$(aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$media_file" --content-type video/mp4 \
  --metadata "scenario=failure-isolation,runid=$run_id" --query VersionId --output text)
transcription_execution=$(start_execution "$transcription_document" \
  "BucketName=$source_bucket,ObjectKey=$source_key,SourceEventId=failure-$run_id")
wait_execution "$transcription_execution" Success >/dev/null
publication_execution=$(start_execution "$publication_document" \
  "SourceBucketName=$source_bucket,SourceObjectKey=$source_key,SourceVersionId=$source_version")
wait_execution "$publication_execution" Success >/dev/null
upstream_baseline=$(upstream_snapshot)
[[ $(jq -r .job_status <<< "$upstream_baseline") == COMPLETED ]]
echo "PASS: durable transcription, artifacts, destination copy, and identity existed before downstream faults"

partition=$(cut -d: -f2 <<< "$confluence_role_arn")
region=$(cut -d: -f4 <<< "$confluence_role_arn")
account=$(cut -d: -f5 <<< "$confluence_role_arn")
deny_policy=$(jq -nc --arg resource \
  "arn:$partition:ssm:$region:$account:automation-definition/$readiness_document:\$DEFAULT" '
  {Version: "2012-10-17", Statement: [{Effect: "Deny",
    Action: "ssm:StartAutomationExecution", Resource: $resource}]}
')
aws iam put-role-policy --role-name "$automation_role_name" \
  --policy-name "$deny_policy_name" --policy-document "$deny_policy"
deny_policy_installed=true
sleep "$iam_settle_seconds"
readiness_failed=$(wait_execution "$(start_execution "$confluence_document" \
  "SourceBucketName=$source_bucket,SourceObjectKey=$source_key")" Failed)
jq -e '.AutomationExecution.StepExecutions[] | select(
  .StepName == "evaluateReadiness" and .StepStatus == "Failed")' \
  >/dev/null <<< "$readiness_failed"
assert_upstream_unchanged
aws iam delete-role-policy --role-name "$automation_role_name" --policy-name "$deny_policy_name"
deny_policy_installed=false
sleep "$iam_settle_seconds"
echo "PASS: failed readiness invocation was diagnosable and preserved every upstream result"

invalid_space="failure-injection-$run_id"
confluence_failed=$(wait_execution "$(start_execution "$confluence_document" \
  "SourceBucketName=$source_bucket,SourceObjectKey=$source_key,ConfluenceSpaceId=$invalid_space")" Failed)
jq -e '.AutomationExecution.StepExecutions[] | select(
  .StepName == "evaluateReadiness" and .StepStatus == "Success")' \
  >/dev/null <<< "$confluence_failed"
jq -e '.AutomationExecution.StepExecutions[] | select(
  .StepName == "publish" and .StepStatus == "Failed")' \
  >/dev/null <<< "$confluence_failed"
assert_upstream_unchanged
echo "PASS: a Confluence API failure occurred after readiness and preserved every upstream result"

# No hint was available. Re-enable only the schedule and require it to discover
# the already complete object and start the same independently retryable publisher.
aws events enable-rule --name "$schedule_rule"
deadline=$((SECONDS + interval_minutes * 60 + timeout_seconds))
while ((SECONDS < deadline)); do
  page_id=$(find_page_id 2>/dev/null || true)
  [[ -z $page_id ]] || break
  sleep "$poll_seconds"
done
if [[ -z $page_id ]]; then
  echo "scheduled reconciliation did not publish $source_key" >&2
  exit 1
fi
assert_upstream_unchanged
page=$(confluence_call GET "/wiki/api/v2/pages/$page_id?body-format=storage")
page_version=$(jq -er .version.number <<< "$page")
echo "PASS: scheduled discovery recovered the missed event and independently repaired Confluence"

repeat=$(wait_execution "$(start_execution "$confluence_document" \
  "SourceBucketName=$source_bucket,SourceObjectKey=$source_key")" Success)
[[ $(jq -er '.AutomationExecution.Outputs | to_entries[] |
  select(.key | endswith(".PageId")) | .value[0]' <<< "$repeat") == "$page_id" ]]
[[ $(confluence_call GET "/wiki/api/v2/pages/$page_id" | jq -er .version.number) == "$page_version" ]]
[[ $(find_page_id) == "$page_id" ]]
assert_upstream_unchanged
echo "PASS: repeat recovery reused one job, artifact pair, destination copy, and Confluence page"

aws events enable-rule --name "$hint_rule"
rules_disabled=false
