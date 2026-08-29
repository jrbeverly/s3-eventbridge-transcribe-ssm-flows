#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${PUBLICATION_TEST_POLL_SECONDS:-5}
timeout_seconds=${PUBLICATION_TEST_TIMEOUT_SECONDS:-300}
iam_settle_seconds=${PUBLICATION_TEST_IAM_SETTLE_SECONDS:-10}

if ! [[ $poll_seconds =~ ^[1-9][0-9]*$ &&
        $timeout_seconds =~ ^[1-9][0-9]*$ &&
        $iam_settle_seconds =~ ^[0-9]+$ ]]; then
  echo "poll, timeout, and IAM settle values must be whole seconds" >&2
  exit 2
fi
for command in aws jq terraform cmp; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

source_bucket=${PUBLICATION_TEST_SOURCE_BUCKET:-$(terraform output -raw source_bucket_name)}
destination_bucket=${PUBLICATION_TEST_DESTINATION_BUCKET:-$(terraform output -raw publication_adapter | jq -r .target)}
automation_document=${PUBLICATION_TEST_AUTOMATION_DOCUMENT:-$(terraform output -raw publication_adapter_automation_document_name)}
automation_role_arn=${PUBLICATION_TEST_AUTOMATION_ROLE_ARN:-$(terraform output -raw publication_adapter_automation_role_arn)}
readiness_document=${PUBLICATION_TEST_READINESS_DOCUMENT:-$(terraform output -raw object_readiness_automation_document_name)}
if [[ -z $source_bucket || -z $destination_bucket || -z $automation_document ||
      -z $automation_role_arn || -z $readiness_document ]]; then
  echo "deploy the Terraform root or set all PUBLICATION_TEST_* resource overrides" >&2
  exit 2
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
fixture_prefix="publication-convergence/$run_id"
source_key="$fixture_prefix/recording + 100%.mp4"
missing_version="publication-test-version-does-not-exist"
temporary_directory=$(mktemp -d)
automation_role_name=${automation_role_arn##*/}
aws_partition=$(cut -d: -f2 <<< "$automation_role_arn")
deny_policy_name="publication-test-deny-$run_id"
deny_policy_installed=false

cleanup() {
  if $deny_policy_installed; then
    aws iam delete-role-policy --role-name "$automation_role_name" \
      --policy-name "$deny_policy_name" >/dev/null 2>&1 || true
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

printf 'publication-version-one\n' > "$temporary_directory/source-v1.mp4"
printf 'publication-version-two\n' > "$temporary_directory/source-v2.mp4"
printf 'conflicting-destination\n' > "$temporary_directory/conflict.mp4"

start_execution() {
  local version_id=${1:-}
  local parameters="SourceBucketName=$source_bucket,SourceObjectKey=$source_key"
  if [[ -n $version_id ]]; then
    parameters+=",SourceVersionId=$version_id"
  fi
  aws ssm start-automation-execution --document-name "$automation_document" \
    --parameters "$parameters" --query AutomationExecutionId --output text
}

start_readiness_execution() {
  aws ssm start-automation-execution --document-name "$readiness_document" \
    --parameters "SourceBucketName=$source_bucket,SourceObjectKey=$source_key" \
    --query AutomationExecutionId --output text
}

wait_execution() {
  local execution_id=$1
  local expected=$2
  local deadline=$((SECONDS + timeout_seconds))
  local response status
  while ((SECONDS < deadline)); do
    response=$(aws ssm get-automation-execution --automation-execution-id "$execution_id" --output json)
    status=$(jq -r '.AutomationExecution.AutomationExecutionStatus' <<< "$response")
    case $status in
      Success|Failed|Cancelled|TimedOut)
        if [[ $status != "$expected" ]]; then
          jq '.AutomationExecution | {AutomationExecutionId, AutomationExecutionStatus, FailureMessage}' \
            <<< "$response" >&2
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

execution_output() {
  jq -er --arg suffix ".$2" '
    .AutomationExecution.Outputs
    | to_entries[]
    | select(.key | endswith($suffix))
    | .value[0]
  ' <<< "$1"
}

head_destination() {
  aws s3api head-object --bucket "$destination_bucket" --key "$source_key" --output json
}

destination_version_count() {
  aws s3api list-object-versions --bucket "$destination_bucket" --prefix "$source_key" \
    --output json | jq -r --arg key "$source_key" \
    '[.Versions[]? | select(.Key == $key)] | length'
}

assert_destination_bytes() {
  local expected=$1
  aws s3api get-object --bucket "$destination_bucket" --key "$source_key" \
    "$temporary_directory/destination.mp4" >/dev/null
  cmp "$expected" "$temporary_directory/destination.mp4"
}

assert_result_matches_destination() {
  local response=$1
  local head details version etag
  head=$(head_destination)
  details=$(execution_output "$response" DestinationDetails)
  version=$(jq -r .VersionId <<< "$head")
  etag=$(jq -r .ETag <<< "$head")
  [[ $(execution_output "$response" DestinationType) == s3 ]]
  [[ $(execution_output "$response" DestinationId) == "$source_key" ]]
  [[ $(execution_output "$response" ConcurrencyToken) == "$version" ]]
  [[ $(jq -r .BucketName <<< "$details") == "$destination_bucket" ]]
  [[ $(jq -r .ObjectKey <<< "$details") == "$source_key" ]]
  [[ $(jq -r .VersionId <<< "$details") == "$version" ]]
  [[ $(jq -r .ETag <<< "$details") == "$etag" ]]
  [[ $(execution_output "$response" MediaUrl) == https://* ]]
}

assert_annotation() {
  local source_version=$1
  local name=$2
  local expected=$3
  local output="$temporary_directory/annotation"
  aws s3api get-object-annotation --bucket "$source_bucket" --key "$source_key" \
    --version-id "$source_version" --annotation-name "$name" "$output" >/dev/null
  [[ $(< "$output") == "$expected" ]]
}

assert_annotation_missing() {
  local source_version=$1
  local name=$2
  local output="$temporary_directory/annotation"
  if aws s3api get-object-annotation --bucket "$source_bucket" --key "$source_key" \
    --version-id "$source_version" --annotation-name "$name" "$output" \
    >/dev/null 2>&1; then
    echo "annotation $name unexpectedly exists on source version $source_version" >&2
    return 1
  fi
}

assert_source_properties() {
  local source_version=$1
  local head tags
  head=$(aws s3api head-object --bucket "$source_bucket" --key "$source_key" \
    --version-id "$source_version" --output json)
  tags=$(aws s3api get-object-tagging --bucket "$source_bucket" --key "$source_key" \
    --version-id "$source_version" --output json)
  [[ $(jq -c .Metadata <<< "$head") == \
    '{"category":"customer-demo","participants":"alice-and-bob","system":"media"}' ]]
  [[ $(jq -c '.TagSet | sort_by(.Key)' <<< "$tags") == \
    '[{"Key":"caller-owned","Value":"preserve-me"}]' ]]
}

source_v1=$(aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$temporary_directory/source-v1.mp4" \
  --metadata 'system=media,category=customer-demo,participants=alice-and-bob' \
  --query VersionId --output text)
aws s3api put-object-tagging --bucket "$source_bucket" --key "$source_key" \
  --version-id "$source_v1" \
  --tagging 'TagSet=[{Key=caller-owned,Value=preserve-me}]'
initial=$(wait_execution "$(start_execution "$source_v1")" Success)
assert_destination_bytes "$temporary_directory/source-v1.mp4"
assert_result_matches_destination "$initial"
destination_v1=$(execution_output "$initial" ConcurrencyToken)
media_url_v1=$(execution_output "$initial" MediaUrl)
assert_annotation "$source_v1" publication.destination s3
assert_annotation "$source_v1" publication.url "$media_url_v1"
assert_annotation "$source_v1" publication.id "$source_key"
assert_annotation "$source_v1" publication.concurrency-token "$destination_v1"
assert_source_properties "$source_v1"
echo "PASS: initial copy bytes, identifiers, token, and annotations match observable S3 state"

count_before=$(destination_version_count)
repeat=$(wait_execution "$(start_execution "$source_v1")" Success)
[[ $(destination_version_count) == "$count_before" ]]
[[ $(execution_output "$repeat" ConcurrencyToken) == "$destination_v1" ]]
echo "PASS: repeated invocation reused the equivalent destination version"

aws s3api delete-object-annotation --bucket "$source_bucket" --key "$source_key" \
  --version-id "$source_v1" --annotation-name publication.url
printf 'stale-version' > "$temporary_directory/stale-annotation"
aws s3api put-object-annotation --bucket "$source_bucket" --key "$source_key" \
  --version-id "$source_v1" --annotation-name publication.concurrency-token \
  --annotation-payload "fileb://$temporary_directory/stale-annotation"
repaired=$(wait_execution "$(start_execution "$source_v1")" Success)
[[ $(destination_version_count) == "$count_before" ]]
assert_annotation "$source_v1" publication.url "$(execution_output "$repaired" MediaUrl)"
assert_annotation "$source_v1" publication.concurrency-token "$destination_v1"
assert_source_properties "$source_v1"
echo "PASS: repeat execution repaired missing and stale annotations without replacing equivalent destination or caller properties"

source_v2=$(aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$temporary_directory/source-v2.mp4" --query VersionId --output text)
changed=$(wait_execution "$(start_execution)" Success)
assert_destination_bytes "$temporary_directory/source-v2.mp4"
assert_result_matches_destination "$changed"
destination_v2=$(execution_output "$changed" ConcurrencyToken)
[[ $destination_v2 != "$destination_v1" ]]
echo "PASS: changed current source overwrote the stable destination key with a new version"

aws s3api delete-object --bucket "$destination_bucket" --key "$source_key" >/dev/null
missing=$(wait_execution "$(start_execution "$source_v2")" Success)
assert_destination_bytes "$temporary_directory/source-v2.mp4"
assert_result_matches_destination "$missing"
assert_annotation "$source_v2" publication.concurrency-token \
  "$(execution_output "$missing" ConcurrencyToken)"
echo "PASS: missing destination was recreated from the pinned source version"

aws s3api put-object --bucket "$destination_bucket" --key "$source_key" \
  --body "$temporary_directory/conflict.mp4" >/dev/null
conflict=$(wait_execution "$(start_execution "$source_v2")" Success)
assert_destination_bytes "$temporary_directory/source-v2.mp4"
assert_result_matches_destination "$conflict"
echo "PASS: conflicting destination was reconciled to the pinned source bytes"

older=$(wait_execution "$(start_execution "$source_v1")" Success)
assert_destination_bytes "$temporary_directory/source-v1.mp4"
assert_result_matches_destination "$older"
assert_annotation "$source_v1" publication.concurrency-token \
  "$(execution_output "$older" ConcurrencyToken)"
echo "PASS: explicit older source version remained addressable and recoverable"

version_before_failure=$(head_destination | jq -r .VersionId)
deny_policy=$(jq -nc --arg resource "arn:$aws_partition:s3:::$destination_bucket/$source_key" '
  {
    Version: "2012-10-17",
    Statement: [{Effect: "Deny", Action: "s3:PutObject", Resource: $resource}]
  }
')
aws iam put-role-policy --role-name "$automation_role_name" --policy-name "$deny_policy_name" \
  --policy-document "$deny_policy"
deny_policy_installed=true
sleep "$iam_settle_seconds"
aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$temporary_directory/source-v2.mp4" >/dev/null
denied=$(wait_execution "$(start_execution)" Failed)
if ! jq -e '.AutomationExecution.StepExecutions[] | select(
    .StepName == "copyToDestination" and .StepStatus == "Failed"
  )' >/dev/null <<< "$denied"; then
  echo "denied execution did not fail at copyToDestination" >&2
  exit 1
fi
[[ $(head_destination | jq -r .VersionId) == "$version_before_failure" ]]
assert_destination_bytes "$temporary_directory/source-v1.mp4"
aws s3api head-object --bucket "$source_bucket" --key "$source_key" >/dev/null
aws iam delete-role-policy --role-name "$automation_role_name" --policy-name "$deny_policy_name"
deny_policy_installed=false
sleep "$iam_settle_seconds"
echo "PASS: denied copy preserved readable source and the previous destination version"

count_before_write_back_failure=$(destination_version_count)
write_back_deny_policy=$(jq -nc \
  --arg resource "arn:$aws_partition:s3:::$source_bucket/$source_key" '
  {
    Version: "2012-10-17",
    Statement: [{Effect: "Deny", Action: "s3:PutObjectAnnotation", Resource: $resource}]
  }
')
aws iam put-role-policy --role-name "$automation_role_name" --policy-name "$deny_policy_name" \
  --policy-document "$write_back_deny_policy"
deny_policy_installed=true
sleep "$iam_settle_seconds"
write_back_failed=$(wait_execution "$(start_execution)" Failed)
if ! jq -e '.AutomationExecution.StepExecutions[] | select(
    .StepName == "copyToDestination" and .StepStatus == "Success"
  )' >/dev/null <<< "$write_back_failed" ||
    ! jq -e '.AutomationExecution.StepExecutions[] | select(
      .StepName == "writePublicationAnnotations" and .StepStatus == "Failed"
    )' >/dev/null <<< "$write_back_failed"; then
  echo "write-back fault did not occur after a successful destination copy" >&2
  exit 1
fi
[[ $(destination_version_count) == $((count_before_write_back_failure + 1)) ]]
assert_destination_bytes "$temporary_directory/source-v2.mp4"
published_version_after_write_back_failure=$(head_destination | jq -r .VersionId)
current_source_version=$(aws s3api head-object --bucket "$source_bucket" --key "$source_key" \
  --query VersionId --output text)
assert_annotation_missing "$current_source_version" publication.destination
assert_annotation_missing "$current_source_version" publication.id
assert_annotation_missing "$current_source_version" publication.url
assert_annotation_missing "$current_source_version" publication.concurrency-token
aws iam delete-role-policy --role-name "$automation_role_name" --policy-name "$deny_policy_name"
deny_policy_installed=false
sleep "$iam_settle_seconds"
write_back_repaired=$(wait_execution "$(start_execution)" Success)
[[ $(destination_version_count) == $((count_before_write_back_failure + 1)) ]]
[[ $(execution_output "$write_back_repaired" ConcurrencyToken) == \
  "$published_version_after_write_back_failure" ]]
assert_annotation "$current_source_version" publication.concurrency-token \
  "$published_version_after_write_back_failure"
echo "PASS: write-back failure retained one successful publication and an independent retry repaired state without another copy"

readiness=$(wait_execution "$(start_readiness_execution)" Success)
destination_facts=$(execution_output "$readiness" DestinationFacts)
[[ $(jq -r .DestinationType <<< "$destination_facts") == s3 ]]
[[ $(jq -r .DestinationId <<< "$destination_facts") == "$source_key" ]]
[[ $(jq -r .ConcurrencyToken <<< "$destination_facts") == \
  "$published_version_after_write_back_failure" ]]
[[ $(jq -r .BucketName <<< "$destination_facts") == "$destination_bucket" ]]
echo "PASS: readiness retrieved the repaired destination identity for downstream Confluence publication"

version_before_failure=$(head_destination | jq -r .VersionId)
failed=$(wait_execution "$(start_execution "$missing_version")" Failed)
[[ $(head_destination | jq -r .VersionId) == "$version_before_failure" ]]
[[ $(aws s3api list-object-versions --bucket "$source_bucket" --prefix "$source_key" \
  --output json | jq -c '[.Versions[] | select(.VersionId != "null")] | length') -ge 2 ]]
assert_annotation "$source_v1" publication.id "$source_key"
if jq -e '.AutomationExecution.StepExecutions[] | select(.StepName == "copyToDestination" and .StepStatus == "Success")' \
  >/dev/null <<< "$failed"; then
  echo "failed source-version validation unexpectedly copied a destination" >&2
  exit 1
fi
echo "PASS: rejected source version preserved recoverable source and destination state"
