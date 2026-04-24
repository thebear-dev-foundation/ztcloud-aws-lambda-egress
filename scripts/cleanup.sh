#!/usr/bin/env bash
# Tear down: Zscaler policy first, then AWS infrastructure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "WARN: $ENV_FILE missing — skipping Zscaler teardown"
  SKIP_ZS=1
fi

API=https://api.zsapi.net

if [ -z "${SKIP_ZS:-}" ]; then
  ZS_VANITY_DOMAIN=$(grep -E '^export ZS_VANITY_DOMAIN=' "$ENV_FILE" | sed 's/^export ZS_VANITY_DOMAIN=//; s/^"//; s/"$//')
  ZS_CLIENT_ID=$(grep -E '^export ZS_CLIENT_ID=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_ID=//; s/^"//; s/"$//')
  ZS_CLIENT_SECRET=$(grep -E '^export ZS_CLIENT_SECRET=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_SECRET=//; s/^"//; s/"$//')
  TOKEN=$(curl -s -X POST "https://${ZS_VANITY_DOMAIN}/oauth2/v1/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${ZS_CLIENT_ID}" \
    --data-urlencode "client_secret=${ZS_CLIENT_SECRET}" \
    --data-urlencode "audience=https://api.zscaler.com" | jq -r '.access_token')

  cd "$ROOT/terraform"
  if [ -f terraform.tfstate ]; then
    INPUTS=$(terraform output -json zscaler_policy_inputs 2>/dev/null || echo '{}')
    IP_GRP_NAME=$(echo "$INPUTS" | jq -r '.ip_source_group_name // empty')
    FW_RULE_NAME=$(echo "$INPUTS" | jq -r '.firewall_rule_name // empty')
    CC_RULE_NAME=$(echo "$INPUTS" | jq -r '.cc_forwarding_rule // empty')

    api() { curl -s -X "$1" "$API$2" -H "Authorization: Bearer $TOKEN"; }

    if [ -n "$FW_RULE_NAME" ]; then
      ID=$(api GET /zia/api/v1/firewallFilteringRules | jq --arg n "$FW_RULE_NAME" '.[] | select(.name == $n) | .id')
      if [ -n "$ID" ]; then echo "DELETE ZIA FW rule $ID ($FW_RULE_NAME)"; api DELETE "/zia/api/v1/firewallFilteringRules/$ID" > /dev/null; sleep 2; fi
    fi

    if [ -n "$IP_GRP_NAME" ]; then
      ID=$(api GET /zia/api/v1/ipSourceGroups | jq --arg n "$IP_GRP_NAME" '.[] | select(.name == $n) | .id')
      if [ -n "$ID" ]; then echo "DELETE ZIA IP Source Group $ID ($IP_GRP_NAME)"; api DELETE "/zia/api/v1/ipSourceGroups/$ID" > /dev/null; sleep 2; fi
    fi

    if [ -n "$CC_RULE_NAME" ]; then
      ID=$(api GET /ztw/api/v1/ecRules/ecRdr | jq --arg n "$CC_RULE_NAME" '.[] | select(.name == $n) | .id')
      if [ -n "$ID" ]; then echo "DELETE CC forwarding rule $ID ($CC_RULE_NAME)"; api DELETE "/ztw/api/v1/ecRules/ecRdr/$ID" > /dev/null; sleep 2; fi
    fi

    echo "Activating ZIA + CC"
    curl -s -X POST "$API/zia/api/v1/status/activate" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"status":"ACTIVE"}' > /dev/null
    curl -s -X PUT  "$API/ztw/api/v1/ecAdminActivateStatus/activate" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"orgEditStatus":"EDITS_PRESENT"}' > /dev/null
  fi
fi

echo "==> terraform destroy"
cd "$ROOT/terraform"
terraform destroy -auto-approve -input=false 2>&1 | tail -15

echo "Cleanup complete."
