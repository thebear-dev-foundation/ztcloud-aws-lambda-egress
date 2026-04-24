#!/usr/bin/env bash
# E2E test: invoke Lambda, show result + CloudWatch logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"

FN=$(terraform output -raw lambda_name)
LOG_GROUP=$(terraform output -raw log_group_name)
REGION="${AWS_REGION:-$(aws configure get region || echo ap-southeast-2)}"

echo "==> Invoking $FN (TCP mode — fast smoke test)"
OUT=$(mktemp)
aws lambda invoke --function-name "$FN" --region "$REGION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"mode":"tcp"}' "$OUT" > /dev/null
echo "--- response ---"
jq . < "$OUT"
rm -f "$OUT"

echo
echo "==> Invoking $FN (SFTP mode — full connect + list + upload)"
OUT=$(mktemp)
aws lambda invoke --function-name "$FN" --region "$REGION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"mode":"sftp"}' "$OUT" > /dev/null
echo "--- response ---"
jq . < "$OUT"
rm -f "$OUT"

echo
echo "==> Recent CloudWatch logs"
aws logs tail "$LOG_GROUP" --region "$REGION" --since 2m | tail -30
