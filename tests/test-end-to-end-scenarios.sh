#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${END_TO_END_POLL_SECONDS:-15}
timeout_seconds=${END_TO_END_TIMEOUT_SECONDS:-1800}
media_file=${END_TO_END_MEDIA_FILE:-}

if [[ -z $media_file || ! -f $media_file ]]; then
  echo "set END_TO_END_MEDIA_FILE to a short, valid English MP4" >&2
  exit 2
fi
if ! [[ $poll_seconds =~ ^[1-9][0-9]*$ && $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "poll and timeout values must be whole positive seconds" >&2
  exit 2
fi
for command in aws curl jq python3 terraform; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

source_bucket=$(terraform output -raw source_bucket_name)
destination_bucket=$(terraform output -json publication_adapter | jq -er .target)
transcription_document=$(terraform output -raw transcription_automation_document_name)
publication_document=$(terraform output -raw publication_adapter_automation_document_name)
confluence_document=$(terraform output -raw confluence_publication_automation_document_name)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
fixture_prefix="end-to-end-scenarios/$run_id"
temporary_directory=$(mktemp -d)
page_ids=()

document=$(aws ssm get-document --name "$confluence_document" \
  --document-version '$DEFAULT' --query Content --output text | jq -e .)
confluence_base_url=${END_TO_END_CONFLUENCE_BASE_URL:-$(jq -er \
  '.mainSteps[] | select(.name == "publish").inputs.InputPayload.ConfluenceBaseUrl' <<< "$document")}
credentials_secret_arn=${END_TO_END_CONFLUENCE_SECRET_ARN:-$(jq -er \
  '.mainSteps[] | select(.name == "publish").inputs.InputPayload.CredentialsSecretArn' <<< "$document")}
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
  local method=$1
  local path=$2
  local output=${3:-/dev/stdout}
  curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
    --netrc-file "$netrc_file" \
    --header 'Accept: application/json' --request "$method" \
    --output "$output" "$confluence_base_url$path"
}

source_marker() {
  python3 - "$source_bucket" "$1" <<'PYTHON'
import hashlib
import sys
print("source-" + hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:32])
PYTHON
}

find_page_id() {
  local marker
  marker=$(source_marker "$1")
  confluence_call GET "/wiki/rest/api/content/search?cql=type%3Dpage%20and%20label%3D%22$marker%22&limit=2" |
    jq -er 'if (.results | length) == 1 then .results[0].id else empty end' 2>/dev/null
}

cleanup() {
  local page_id versions
  for key in "$happy_key" "$duplicate_key" "$out_of_order_key" "$overwrite_key"; do
    page_id=$(find_page_id "$key" 2>/dev/null || true)
    if [[ -n $page_id ]]; then
      page_ids+=("$page_id")
    fi
  done
  if ((${#page_ids[@]})); then
    while IFS= read -r page_id; do
      [[ -n $page_id ]] || continue
      confluence_call DELETE "/wiki/api/v2/pages/$page_id" /dev/null >/dev/null 2>&1 || true
    done < <(printf '%s\n' "${page_ids[@]}" | sort -u)
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

happy_key="$fixture_prefix/happy/representative.mp4"
duplicate_key="$fixture_prefix/duplicate/representative.mp4"
out_of_order_key="$fixture_prefix/out-of-order/representative.mp4"
overwrite_key="$fixture_prefix/overwrite/representative.mp4"
trap cleanup EXIT
echo "end-to-end fixture prefix: $fixture_prefix"

start_transcription() {
  aws ssm start-automation-execution --document-name "$transcription_document" \
    --parameters "BucketName=$source_bucket,ObjectKey=$1,SourceEventId=e2e-$run_id-$2" \
    --query AutomationExecutionId --output text
}

start_publication() {
  local parameters="SourceBucketName=$source_bucket,SourceObjectKey=$1"
  [[ -z ${2:-} ]] || parameters+=",SourceVersionId=$2"
  aws ssm start-automation-execution --document-name "$publication_document" \
    --parameters "$parameters" --query AutomationExecutionId --output text
}

start_confluence() {
  aws ssm start-automation-execution --document-name "$confluence_document" \
    --parameters "SourceBucketName=$source_bucket,SourceObjectKey=$1" \
    --query AutomationExecutionId --output text
}

wait_execution_success() {
  local execution_id=$1 deadline=$((SECONDS + timeout_seconds)) response status
  while ((SECONDS < deadline)); do
    response=$(aws ssm get-automation-execution \
      --automation-execution-id "$execution_id" --output json)
    status=$(jq -r '.AutomationExecution.AutomationExecutionStatus' <<< "$response")
    case $status in
      Success)
        return
        ;;
      Failed|Cancelled|TimedOut)
        jq '.AutomationExecution | {AutomationExecutionId, DocumentName,
          AutomationExecutionStatus, FailureMessage, Outputs}' <<< "$response" >&2
        return 1
        ;;
    esac
    sleep "$poll_seconds"
  done
  echo "execution $execution_id did not finish within $timeout_seconds seconds" >&2
  return 1
}

upload_fixture() {
  local key=$1
  local scenario=$2
  aws s3api put-object --bucket "$source_bucket" --key "$key" --body "$media_file" \
    --content-type video/mp4 \
    --metadata "scenario=$scenario,participants=alice-and-bob,runid=$run_id" \
    --query VersionId --output text
}

annotation_value() {
  local key=$1 version=$2 name=$3 output="$temporary_directory/annotation-$RANDOM"
  if aws s3api get-object-annotation --bucket "$source_bucket" --key "$key" \
    --version-id "$version" --annotation-name "$name" "$output" >/dev/null 2>&1; then
    tr -d '\r\n' < "$output"
  fi
  rm -f "$output"
}

automation_observations() {
  local key=$1
  for document_name in "$transcription_document" "$publication_document" "$confluence_document"; do
    aws ssm describe-automation-executions \
      --filters "Key=DocumentNamePrefix,Values=$document_name" \
      --max-results 20 --output json 2>/dev/null | jq -c --arg key "$key" '
        [.AutomationExecutionMetadataList[]
         | select(any(.AutomationExecutionParameters[]?[]?; . == $key))
         | {document: .DocumentName, id: .AutomationExecutionId,
            status: .AutomationExecutionStatus, failure: .FailureMessage}][:5]'
  done
}

snapshot() {
  local key=$1 version=$2 vtt_key=${1%.mp4}.transcription.vtt
  local source_head vtt_head destination_head page_id page page_body
  source_head=$(aws s3api head-object --bucket "$source_bucket" --key "$key" \
    --version-id "$version" --output json 2>/dev/null || echo null)
  vtt_head=$(aws s3api head-object --bucket "$source_bucket" --key "$vtt_key" \
    --output json 2>/dev/null || echo null)
  destination_head=$(aws s3api head-object --bucket "$destination_bucket" --key "$key" \
    --output json 2>/dev/null || echo null)
  page_id=$(find_page_id "$key" 2>/dev/null || true)
  page=null
  if [[ -n $page_id ]]; then
    page_body="$temporary_directory/page-$page_id.json"
    if confluence_call GET "/wiki/api/v2/pages/$page_id?body-format=storage" "$page_body" \
      >/dev/null 2>&1; then
      page=$(jq -c '{id, version: .version.number, body: .body.storage.value}' "$page_body")
    fi
  fi
  jq -nc --arg key "$key" --arg version "$version" \
    --arg destination "$(annotation_value "$key" "$version" publication.destination)" \
    --arg destination_id "$(annotation_value "$key" "$version" publication.id)" \
    --arg media_url "$(annotation_value "$key" "$version" publication.url)" \
    --arg concurrency "$(annotation_value "$key" "$version" publication.concurrency-token)" \
    --argjson source "$source_head" --argjson vtt "$vtt_head" \
    --argjson published "$destination_head" --argjson page "$page" \
    '{key: $key, expected_source_version: $version, source: $source, vtt: $vtt,
      destination: $published, annotations: {destination: $destination,
      id: $destination_id, url: $media_url, concurrency: $concurrency}, page: $page}'
}

state_is_complete() {
  local state=$1 key=$2 version=$3 expected_scenario=$4
  jq -e --arg key "$key" --arg version "$version" --arg run "$run_id" \
    --arg scenario "$expected_scenario" '
    .source.VersionId == $version and
    .source.ContentType == "video/mp4" and
    .source.Metadata == {scenario: $scenario,
                         participants: "alice-and-bob", runid: $run} and
    .vtt.VersionId != null and .vtt.ContentLength > 0 and
    .vtt.ContentType == "text/vtt; charset=utf-8" and
    .vtt.Metadata.sourceversionid == $version and
    .destination.VersionId == .annotations.concurrency and
    .destination.ETag == .source.ETag and
    .destination.ContentLength == .source.ContentLength and
    .annotations.destination == "s3" and .annotations.id == $key and
    (.annotations.url | startswith("https://")) and
    .page.id != null' <<< "$state" >/dev/null
}

assert_page_content() {
  local key=$1 version=$2 state=$3
  local page_id vtt_key=${key%.mp4}.transcription.vtt
  page_id=$(jq -er .page.id <<< "$state")
  aws s3api get-object --bucket "$source_bucket" --key "$vtt_key" \
    "$temporary_directory/vtt-$page_id" >/dev/null
  jq -r .page.body <<< "$state" > "$temporary_directory/body-$page_id"
  python3 - "$temporary_directory/vtt-$page_id" "$temporary_directory/body-$page_id" \
    "$source_bucket" "$key" "$version" "$(jq -r .source.ETag <<< "$state")" \
    "$(jq -r .annotations.url <<< "$state")" "$(jq -r .annotations.id <<< "$state")" \
    "$(jq -r .annotations.concurrency <<< "$state")" "$run_id" <<'PYTHON'
import html
import pathlib
import sys

vtt_path, body_path, bucket, key, version, etag, url, destination_id, token, run_id = sys.argv[1:]
vtt = pathlib.Path(vtt_path).read_text(encoding="utf-8")
body = pathlib.Path(body_path).read_text(encoding="utf-8")
assert vtt.startswith("WEBVTT"), "stable artifact is not complete WEBVTT"
required = [html.escape(vtt, quote=False), bucket + "/" + key, version, etag,
            url, destination_id, token, "scenario", "participants",
            "alice-and-bob", "runid", run_id, "Open published media"]
missing = [value for value in required if html.escape(value, quote=False) not in body]
assert not missing, "Confluence body is missing: " + repr(missing)
PYTHON
}

wait_for_complete_state() {
  local scenario=$1 key=$2 version=$3 expected_metadata=$4
  local deadline=$((SECONDS + timeout_seconds)) state
  while ((SECONDS < deadline)); do
    state=$(snapshot "$key" "$version")
    if state_is_complete "$state" "$key" "$version" "$expected_metadata"; then
      if assert_page_content "$key" "$version" "$state"; then
        printf '%s\n' "$state"
        return
      fi
      echo "FAIL: $scenario reached complete infrastructure state but Confluence content was incomplete" >&2
      jq . <<< "$state" >&2
      automation_observations "$key" | jq . >&2
      return 1
    fi
    sleep "$poll_seconds"
  done
  echo "FAIL: $scenario did not converge within $timeout_seconds seconds" >&2
  snapshot "$key" "$version" | jq . >&2
  echo "recent matching Automation observations:" >&2
  automation_observations "$key" | jq . >&2
  return 1
}

happy_version=$(upload_fixture "$happy_key" happy)
happy_publication=$(start_publication "$happy_key" "$happy_version")
happy_state=$(wait_for_complete_state happy-path "$happy_key" "$happy_version" happy)
echo "PASS: happy path exposed complete VTT, destination identity/link, arbitrary properties, and source context"

duplicate_v1=$(upload_fixture "$duplicate_key" duplicate)
duplicate_version=$(upload_fixture "$duplicate_key" duplicate)
[[ $duplicate_v1 != "$duplicate_version" ]]
duplicate_transcription_one=$(start_transcription "$duplicate_key" duplicate-one)
duplicate_transcription_two=$(start_transcription "$duplicate_key" duplicate-two)
duplicate_publication_one=$(start_publication "$duplicate_key" "$duplicate_version")
duplicate_publication_two=$(start_publication "$duplicate_key" "$duplicate_version")
wait_for_complete_state duplicate-upload-events "$duplicate_key" "$duplicate_version" duplicate >/dev/null
echo "PASS: duplicate upload notifications converged through executions $duplicate_transcription_one and $duplicate_transcription_two without divergent state"

out_of_order_version=$(upload_fixture "$out_of_order_key" out-of-order)
early_publication=$(start_publication "$out_of_order_key" "$out_of_order_version")
early_confluence=$(start_confluence "$out_of_order_key")
wait_for_complete_state out-of-order-completion "$out_of_order_key" "$out_of_order_version" out-of-order >/dev/null
echo "PASS: publication $early_publication and readiness check $early_confluence ran before transcription completion and later converged"

overwrite_v1=$(upload_fixture "$overwrite_key" overwrite-v1)
overwrite_v2=$(upload_fixture "$overwrite_key" overwrite-v2)
[[ $overwrite_v1 != "$overwrite_v2" ]]
overwrite_publication=$(start_publication "$overwrite_key" "$overwrite_v2")
overwrite_state=$(wait_for_complete_state source-overwrite "$overwrite_key" "$overwrite_v2" overwrite-v2)
[[ $(jq -r .source.Metadata.scenario <<< "$overwrite_state") == overwrite-v2 ]]
echo "PASS: source overwrite converged every current observable to version $overwrite_v2"

destination_version_before=$(jq -r .destination.VersionId <<< "$happy_state")
page_version_before=$(jq -r .page.version <<< "$happy_state")
repeat_transcription=$(start_transcription "$happy_key" repeat)
repeat_publication=$(start_publication "$happy_key" "$happy_version")
repeat_confluence=$(start_confluence "$happy_key")
wait_execution_success "$repeat_transcription"
wait_execution_success "$repeat_publication"
wait_execution_success "$repeat_confluence"
repeat_state=$(wait_for_complete_state repeat-reconciliation "$happy_key" "$happy_version" happy)
[[ $(jq -r .destination.VersionId <<< "$repeat_state") == "$destination_version_before" ]]
[[ $(jq -r .page.version <<< "$repeat_state") == "$page_version_before" ]]
echo "PASS: repeat reconciliation $repeat_transcription/$repeat_publication/$repeat_confluence preserved destination and page versions"

# Do not let manually started duplicate/out-of-order executions outlive fixture cleanup.
for execution_id in "$happy_publication" \
  "$duplicate_transcription_one" "$duplicate_transcription_two" \
  "$duplicate_publication_one" "$duplicate_publication_two" \
  "$early_publication" "$early_confluence" "$overwrite_publication"; do
  wait_execution_success "$execution_id"
done
