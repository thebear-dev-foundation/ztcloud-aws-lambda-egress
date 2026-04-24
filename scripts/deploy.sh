#!/usr/bin/env bash
# Deploy AWS-side infrastructure: subnet + SG + Lambda + IAM + secret.
# Pass inputs as flags OR via terraform.tfvars in terraform/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

VPC_ID=""
ROUTE_TABLE_ID=""
SUBNET_CIDR=""
AZ=""

while [ $# -gt 0 ]; do
  case "$1" in
    --vpc-id)             VPC_ID="$2"; shift 2 ;;
    --route-table-id)     ROUTE_TABLE_ID="$2"; shift 2 ;;
    --subnet-cidr)        SUBNET_CIDR="$2"; shift 2 ;;
    --availability-zone)  AZ="$2"; shift 2 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

for v in VPC_ID ROUTE_TABLE_ID SUBNET_CIDR AZ; do
  if [ -z "${!v}" ]; then
    echo "ERROR: --${v,,} is required (or set in terraform.tfvars)"
    echo "Usage: $0 --vpc-id vpc-... --route-table-id rtb-... --subnet-cidr 10.x.y.z/28 --availability-zone ap-southeast-2a"
    exit 1
  fi
done

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and populate."
  exit 1
fi

echo "==> Loading SFTP credentials from $ENV_FILE"
SFTP_HOST=$(grep -E '^export SFTP_HOST=' "$ENV_FILE" | sed 's/^export SFTP_HOST=//; s/^"//; s/"$//')
SFTP_PORT=$(grep -E '^export SFTP_PORT=' "$ENV_FILE" | sed 's/^export SFTP_PORT=//; s/^"//; s/"$//')
SFTP_USER=$(grep -E '^export SFTP_USER=' "$ENV_FILE" | sed 's/^export SFTP_USER=//; s/^"//; s/"$//')
SFTP_PASSWORD=$(grep -E '^export SFTP_PASSWORD=' "$ENV_FILE" | sed 's/^export SFTP_PASSWORD=//; s/^"//; s/"$//')

[ -f "$ROOT/terraform/lambda/build/lambda.zip" ] || { echo "ERROR: lambda/build/lambda.zip not built. Run ./scripts/build-lambda.sh first."; exit 1; }

echo "==> AWS identity"
aws sts get-caller-identity --query Arn --output text

cd "$ROOT/terraform"
terraform init -upgrade -input=false

terraform apply -auto-approve -input=false \
  -var "vpc_id=$VPC_ID" \
  -var "route_table_id=$ROUTE_TABLE_ID" \
  -var "subnet_cidr=$SUBNET_CIDR" \
  -var "availability_zone=$AZ" \
  -var "sftp_host=$SFTP_HOST" \
  -var "sftp_port=$SFTP_PORT" \
  -var "sftp_user=$SFTP_USER" \
  -var "sftp_password=$SFTP_PASSWORD"

echo
echo "==> AWS deploy complete. Terraform outputs:"
terraform output
echo
echo "Next: ./scripts/deploy-zscaler-policy.sh   (creates ZIA + CC forwarding rules)"
