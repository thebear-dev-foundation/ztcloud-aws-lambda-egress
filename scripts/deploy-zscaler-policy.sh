#!/usr/bin/env bash
# Create Zscaler-side policy (ZIA + CC) via OneAPI, using inputs from terraform outputs.
#
# Creates (idempotent by name):
#   1. ZIA IP Source Group             — the subnet CIDR
#   2. ZIA Network Service (if custom  — if sftp_port != 22)
#   3. ZIA Firewall Filtering rule     — allow IP group → sftp_host on SFTP service
#   4. CC Forwarding rule              — steer this subnet's traffic through ZIA
# Then activates ZIA + CC.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

ZS_VANITY_DOMAIN=$(grep -E '^export ZS_VANITY_DOMAIN=' "$ENV_FILE" | sed 's/^export ZS_VANITY_DOMAIN=//; s/^"//; s/"$//')
ZS_CLIENT_ID=$(grep -E '^export ZS_CLIENT_ID=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_ID=//; s/^"//; s/"$//')
ZS_CLIENT_SECRET=$(grep -E '^export ZS_CLIENT_SECRET=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_SECRET=//; s/^"//; s/"$//')

API=https://api.zsapi.net

echo "==> Reading terraform outputs"
cd "$ROOT/terraform"
INPUTS=$(terraform output -json zscaler_policy_inputs)
SUBNET_CIDR=$(echo "$INPUTS" | jq -r '.subnet_cidr')
SFTP_HOST=$(echo "$INPUTS" | jq -r '.sftp_host')
SFTP_PORT=$(echo "$INPUTS" | jq -r '.sftp_port')
IP_GRP_NAME=$(echo "$INPUTS" | jq -r '.ip_source_group_name')
FW_RULE_NAME=$(echo "$INPUTS" | jq -r '.firewall_rule_name')
CC_RULE_NAME=$(echo "$INPUTS" | jq -r '.cc_forwarding_rule')

echo "   subnet_cidr=$SUBNET_CIDR  sftp=$SFTP_HOST:$SFTP_PORT"

echo "==> Obtaining OneAPI token"
TOKEN=$(curl -s -X POST "https://${ZS_VANITY_DOMAIN}/oauth2/v1/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${ZS_CLIENT_ID}" \
  --data-urlencode "client_secret=${ZS_CLIENT_SECRET}" \
  --data-urlencode "audience=https://api.zscaler.com" | jq -r '.access_token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "token fetch failed"; exit 1; }

api() { # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$b"
  else
    curl -s -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN"
  fi
}

# --- 1. ZIA IP Source Group ---
echo "==> 1. ZIA IP Source Group: $IP_GRP_NAME"
EXISTING=$(api GET /zia/api/v1/ipSourceGroups | jq --arg n "$IP_GRP_NAME" '.[] | select(.name == $n) | .id')
if [ -n "$EXISTING" ]; then
  IP_GRP_ID="$EXISTING"
  echo "   exists (id=$IP_GRP_ID) — updating CIDR"
  BODY=$(jq -n --arg n "$IP_GRP_NAME" --arg c "$SUBNET_CIDR" \
    '{name: $n, ipAddresses: [$c], description: "Lambda SFTP egress subnet (managed by ztcloud-aws-lambda-egress)"}')
  api PUT "/zia/api/v1/ipSourceGroups/$IP_GRP_ID" "$BODY" > /dev/null
else
  BODY=$(jq -n --arg n "$IP_GRP_NAME" --arg c "$SUBNET_CIDR" \
    '{name: $n, ipAddresses: [$c], description: "Lambda SFTP egress subnet (managed by ztcloud-aws-lambda-egress)"}')
  RESP=$(api POST /zia/api/v1/ipSourceGroups "$BODY")
  IP_GRP_ID=$(echo "$RESP" | jq -r '.id')
  echo "   created (id=$IP_GRP_ID)"
fi
sleep 2

# --- 2. ZIA Network Service (if non-22) ---
NW_SVC_ID=""
if [ "$SFTP_PORT" -eq 22 ]; then
  echo "==> 2. ZIA Network Service: using built-in SSH (port 22)"
  NW_SVC_ID=$(api GET /zia/api/v1/networkServices | jq '.[] | select(.name == "SSH") | .id' | head -1)
else
  SVC_NAME="SFTP-Custom-Port-$SFTP_PORT"
  echo "==> 2. ZIA Network Service: $SVC_NAME"
  EXISTING=$(api GET /zia/api/v1/networkServices | jq --arg n "$SVC_NAME" '.[] | select(.name == $n) | .id')
  if [ -n "$EXISTING" ]; then
    NW_SVC_ID="$EXISTING"
    echo "   exists (id=$NW_SVC_ID)"
  else
    BODY=$(jq -n --arg n "$SVC_NAME" --argjson p "$SFTP_PORT" \
      '{name: $n, type: "CUSTOM", destTcpPorts: [{start: $p, end: $p}]}')
    RESP=$(api POST /zia/api/v1/networkServices "$BODY")
    NW_SVC_ID=$(echo "$RESP" | jq -r '.id')
    echo "   created (id=$NW_SVC_ID)"
  fi
fi
sleep 2

# --- 3. ZIA Firewall Filtering rule ---
echo "==> 3. ZIA Firewall rule: $FW_RULE_NAME"
EXISTING=$(api GET /zia/api/v1/firewallFilteringRules | jq --arg n "$FW_RULE_NAME" '.[] | select(.name == $n) | .id')
FW_BODY=$(jq -n \
  --arg n  "$FW_RULE_NAME" \
  --arg h  "$SFTP_HOST" \
  --argjson g "$IP_GRP_ID" \
  --argjson s "$NW_SVC_ID" \
  '{
    name: $n,
    description: "Lambda SFTP egress — narrow allow",
    order: 1,
    rank: 7,
    state: "ENABLED",
    action: "ALLOW",
    srcIpGroups: [{id: $g}],
    nwServices: [{id: $s}],
    destAddresses: [$h]
  }')
if [ -n "$EXISTING" ]; then
  echo "   exists (id=$EXISTING) — updating"
  api PUT "/zia/api/v1/firewallFilteringRules/$EXISTING" "$FW_BODY" > /dev/null
  FW_RULE_ID="$EXISTING"
else
  RESP=$(api POST /zia/api/v1/firewallFilteringRules "$FW_BODY")
  FW_RULE_ID=$(echo "$RESP" | jq -r '.id')
  echo "   created (id=$FW_RULE_ID)"
fi
sleep 2

# --- 4. CC Forwarding rule (LOCAL_SWITCH to ZIA) ---
echo "==> 4. CC Forwarding rule: $CC_RULE_NAME"
EXISTING=$(api GET /ztw/api/v1/ecRules/ecRdr | jq --arg n "$CC_RULE_NAME" '.[] | select(.name == $n) | .id')
CC_BODY=$(jq -n \
  --arg n "$CC_RULE_NAME" \
  --arg c "$SUBNET_CIDR" \
  --arg h "$SFTP_HOST" \
  '{
    name: $n,
    description: "Lambda SFTP egress — steer this subnet through ZIA",
    type: "EC_RDR",
    rank: 7,
    order: 1,
    forwardMethod: "ZIA",
    state: "ENABLED",
    srcIps: [$c],
    destAddresses: [$h]
  }')
if [ -n "$EXISTING" ]; then
  echo "   exists (id=$EXISTING) — updating"
  api PUT "/ztw/api/v1/ecRules/ecRdr/$EXISTING" "$CC_BODY" > /dev/null
else
  RESP=$(api POST /ztw/api/v1/ecRules/ecRdr "$CC_BODY")
  echo "   created (id=$(echo "$RESP" | jq -r '.id'))"
fi
sleep 2

# --- 5. Activate ---
echo "==> 5a. Activate ZIA"
api POST /zia/api/v1/status/activate '{"status":"ACTIVE"}' | jq . >/dev/null
echo "==> 5b. Activate ZTW (CC)"
api PUT /ztw/api/v1/ecAdminActivateStatus/activate '{"orgEditStatus":"EDITS_PRESENT"}' | jq . >/dev/null

echo
echo "Zscaler policy deployed. Allow 30-60 sec for propagation to CCs in the region."
echo "Next: ./scripts/test.sh"
