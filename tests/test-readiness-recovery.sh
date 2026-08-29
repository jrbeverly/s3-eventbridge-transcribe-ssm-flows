#!/usr/bin/env bash

set -euo pipefail

poll_seconds=${READINESS_RECOVERY_POLL_SECONDS:-15}
grace_seconds=${READINESS_RECOVERY_GRACE_SECONDS:-300}

for command in aws jq terraform; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

source_bucket=$(terraform output -raw source_bucket_name)
reconciliation=$(terraform output -json readiness_reconciliation)
trigger_document=$(jq -r .automation_document_name <<< "$reconciliation")
hint_rule=$(jq -r .event_rule_name <<< "$reconciliation")
interval_minutes=$(jq -r .interval_minutes <<< "$reconciliation")
publication_document=$(terraform output -raw confluence_publication_automation_document_name)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
source_key="readiness-recovery/$run_id/missed.mp4"
temporary_directory=$(mktemp -d)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cleanup() {
  aws events enable-rule --name "$hint_rule" >/dev/null 2>&1 || true
  versions=$(aws s3api list-object-versions --bucket "$source_bucket" \
    --prefix "readiness-recovery/$run_id/" --output json 2>/dev/null |
    jq -c '[((.Versions // []) + (.DeleteMarkers // []))[] | {Key, VersionId}]') || true
  if [[ -n ${versions:-} && $versions != '[]' ]]; then
    aws s3api delete-objects --bucket "$source_bucket" \
      --delete "$(jq -nc --argjson objects "$versions" '{Objects: $objects, Quiet: true}')" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

printf 'deliberately missed readiness hint\n' > "$temporary_directory/missed.mp4"
aws events disable-rule --name "$hint_rule"
aws s3api put-object --bucket "$source_bucket" --key "$source_key" \
  --body "$temporary_directory/missed.mp4" --content-type video/mp4 >/dev/null
aws events enable-rule --name "$hint_rule"
echo "PASS: uploaded fixture while the readiness hint rule was disabled"

deadline=$((SECONDS + interval_minutes * 60 + grace_seconds))
while ((SECONDS < deadline)); do
  while IFS= read -r trigger_id; do
    [[ -n $trigger_id ]] || continue
    trigger=$(aws ssm get-automation-execution \
      --automation-execution-id "$trigger_id" --output json)
    if [[ $(jq -r '.AutomationExecution.Parameters.ChangedObjectKey[0] // ""' \
      <<< "$trigger") != "" ]]; then
      continue
    fi
    while IFS= read -r child_id; do
      [[ -n $child_id ]] || continue
      child=$(aws ssm get-automation-execution \
        --automation-execution-id "$child_id" --output json)
      if [[ $(jq -r '.AutomationExecution.DocumentName' <<< "$child") == "$publication_document" &&
            $(jq -r '.AutomationExecution.Parameters.SourceObjectKey[0]' <<< "$child") == "$source_key" ]]; then
        echo "PASS: scheduled reconciliation recovered $source_key through publication execution $child_id"
        exit 0
      fi
    done < <(jq -r '
      .AutomationExecution.Outputs["dispatchReadiness.ExecutionIds"][]? // empty
    ' <<< "$trigger")
  done < <(aws ssm describe-automation-executions \
    --filters "Key=DocumentNamePrefix,Values=$trigger_document" \
      "Key=StartTimeAfter,Values=$started_at" \
    --query 'AutomationExecutionMetadataList[].AutomationExecutionId' \
    --output text | tr '\t' '\n')
  sleep "$poll_seconds"
done

echo "scheduled reconciliation did not recover $source_key within ${interval_minutes} minutes plus ${grace_seconds} seconds" >&2
exit 1
