# ztcloud-aws-lambda-egress

Reference implementation for steering **AWS Lambda egress traffic through Zscaler Cloud Connector + ZIA**, using a subnet-based identifier that lets the customer's security team write precise allow-list policy for a Lambda-hosted workflow.

The worked example is **SFTP egress** — a Lambda that connects to an external SFTP server — but the pattern applies to any Lambda outbound traffic that needs Zscaler policy enforcement.

## Problem this solves

An AWS Lambda needs to make an outbound connection (SFTP, API, custom TCP) to an external destination. The security team wants:
- All Lambda egress inspected by Zscaler
- Policy allowing *only this specific Lambda* to reach the destination
- An auditable identifier that ties the Lambda to the policy rule

**The constraint**: ZIA and the Zscaler Cloud Connector see only packets, not AWS control-plane metadata. IAM role, Lambda function ARN, and Lambda resource tags are invisible to Zscaler policy. The only network-observable identifier is the source IP.

**The solution**: dedicate a VPC subnet to the Lambda, tag it, and use the subnet CIDR as the Zscaler policy anchor (either directly as an IP Source Group or via a Workload Group discovered by WDS).

## Architecture (summary)

```
VPC
└── subnet "lambda-sftp-egress" (/28)
    │  tags: zscaler-egress-profile=sftp, workload-group=sftp-egress
    │  route table → GWLBe → Cloud Connector
    │
    ├── Lambda SFTP client (VpcConfig pins to this subnet)
    └── Security Group: egress tcp/22 to SFTP dest only

  Cloud Connector
    │  forwarding rule: srcIps=subnet-CIDR, destAddresses=sftp-host → ZIA
    │
  ZIA
    │  IP Source Group: "AWS-Lambda-SFTP-Egress" = subnet CIDR
    │  Firewall Filtering rule: srcIpGroups=[above], dest=sftp-host, nwService=SSH, action=ALLOW
    │  (SSL Inspection bypass if SFTP-over-SSH — not HTTPS, can't decrypt)
    │
  Internet / SFTP server
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for full design, identifier strategy, defense-in-depth controls, and risk register.

## Repository layout

```
ztcloud-aws-lambda-egress/
├── README.md                        — this file
├── ARCHITECTURE.md                  — design, identifier strategy, security
├── LICENSE                          — Apache 2.0
├── CHANGELOG.md
├── .env.example                     — OneAPI + SFTP credential template
├── .gitignore
├── terraform/
│   ├── main.tf                      — AWS subnet + SG + Lambda + IAM + secret
│   ├── variables.tf                 — module inputs
│   ├── outputs.tf                   — outputs (subnet CIDR — feeds Zscaler policy)
│   └── lambda/
│       ├── handler.py               — paramiko SFTP client with TCP-only fallback
│       └── requirements.txt         — paramiko
└── scripts/
    ├── build-lambda.sh              — build amd64 deployment zip (paramiko + handler)
    ├── deploy.sh                    — terraform apply (AWS side)
    ├── deploy-zscaler-policy.sh     — OneAPI: IP Source Group + FW rule + CC rule
    ├── test.sh                      — invoke Lambda, verify SFTP, show logs
    └── cleanup.sh                   — tear down both sides
```

## Prerequisites

1. **AWS Lab / environment with Zscaler CCs already deployed**. This module does NOT provision VPC/TGW/Cloud Connector infrastructure — it assumes that foundation exists (typical LZA-TSE Perimeter account pattern).
2. Customer inputs required:
   - `vpc_id` — VPC where the Lambda subnet lives (typically Workload / App VPC)
   - `route_table_id` — existing route table that steers `0.0.0.0/0` through the Cloud Connector GWLBe
   - `subnet_cidr` — a free /28 (or /27) CIDR in the VPC's address space
   - `availability_zone` — where the subnet goes
3. Zscaler OneAPI client (ZIdentity OAuth2 client with access to `/zia/*` and `/ztw/*`)
4. SFTP test target (FQDN/IP + credentials)

## Quickstart

```bash
# 1. Configure credentials
cp .env.example .env
# edit .env — populate Zscaler OneAPI + SFTP test target

# 2. Build the Lambda deployment zip (needs Docker OR Python 3.12 + pip with --platform support)
./scripts/build-lambda.sh

# 3. Deploy AWS side
./scripts/deploy.sh \
  --vpc-id vpc-0abc... \
  --route-table-id rtb-0def... \
  --subnet-cidr 10.100.7.0/28 \
  --availability-zone ap-southeast-2a

# 4. Deploy Zscaler-side policy (uses terraform outputs to populate OneAPI)
./scripts/deploy-zscaler-policy.sh

# 5. Test: invoke the Lambda, verify SFTP connection succeeded, check Zscaler logs
./scripts/test.sh
```

## What each deploy does

**`deploy.sh` (AWS side, Terraform):**
- Creates the dedicated subnet with identifier tags (`zscaler-egress-profile=sftp`, `workload-group=sftp-egress`)
- Creates a Security Group restricting egress to SFTP destination on port 22 only
- Deploys the SFTP-client Lambda (VPC-attached to the new subnet)
- Creates the Lambda IAM role (CloudWatch Logs + Secrets Manager only)
- Stores SFTP credentials in Secrets Manager (CMK-encrypted in production — see ARCHITECTURE.md §5)
- Outputs the subnet CIDR — the **single identifier** that feeds Zscaler policy

**`deploy-zscaler-policy.sh` (Zscaler side, OneAPI):**
- Creates ZIA IP Source Group from the subnet CIDR
- Creates ZIA Network Service for SFTP (custom port if non-22)
- Creates ZIA Firewall Filtering rule: allow from IP group to SFTP destination on SSH/custom port
- Creates Cloud Connector forwarding rule: steer this subnet's traffic through ZIA (LOCAL_SWITCH → ZIA)
- Activates both (ZIA `POST /status/activate` + ZTW `PUT /ecAdminActivateStatus/activate`)

## Identifier strategy — what ties it all together

**The subnet CIDR is the only identifier that Zscaler can see.** Everything else is bookkeeping to make this identifier auditable and hard to misuse:

| Layer | Mechanism | Purpose |
|---|---|---|
| AWS Lambda VpcConfig | pinned to the subnet | only this subnet's ENIs are assigned to this Lambda |
| AWS SCP | deny `lambda:UpdateFunctionConfiguration` that changes VpcConfig | lock the Lambda to its subnet |
| AWS Security Group | egress tcp/22 to SFTP destination only | defense-in-depth at the ENI |
| AWS Subnet tag | `zscaler-egress-profile=sftp` | AWS-side audit; can be referenced by Zscaler Workload Groups if WDS enabled |
| Zscaler IP Source Group | subnet CIDR | ZIA FW rule source anchor |
| Zscaler Workload Group (optional) | tag match via WDS | higher-abstraction policy that survives subnet CIDR changes |
| Zscaler FW rule | srcIpGroups + destination + service | the actual allow decision |

**What the customer CANNOT use** (frequently asked):
- ❌ IAM execution role — not visible in packets
- ❌ Lambda function ARN / name — not visible in packets
- ❌ AWS resource tags on the Lambda itself — Zscaler doesn't introspect Lambda config
- ❌ AWS account ID at ZIA — ZIA sees only the post-GENEVE-decap source IP

See [ARCHITECTURE.md §4](ARCHITECTURE.md) for the identifier-strategy deep dive and the identifier-matrix rationale.

## Security (summary)

- **Least-privilege IAM** — Lambda role limited to CloudWatch Logs + one Secrets Manager ARN.
- **SFTP credentials** — stored in Secrets Manager, never passed as env vars, rotated per customer policy.
- **Egress lock-down** — Security Group restricts outbound to SFTP destination only; NACL on subnet for an extra layer if required.
- **Policy defense-in-depth** — AWS SG + AWS NACL + AWS route table + Zscaler CC forwarding rule + ZIA FW rule + (optional) ZIA URL filtering all independently agree on what traffic is allowed.
- **Observability** — CloudWatch Logs for the Lambda, VPC Flow Logs on the subnet, ZIA Web Insights/Firewall logs for the egress flow.

See [ARCHITECTURE.md §5](ARCHITECTURE.md#5-security-model) for the full threat model.

## Testing

```bash
./scripts/test.sh
```

Verifies:
1. Lambda invocation succeeds.
2. CloudWatch logs show SFTP connect + LIST + upload.
3. Direct egress without Zscaler is blocked (control test).
4. Zscaler-side policy evaluation logs the flow (requires Zscaler Web Insights access).

## Contributing

PRs welcome for:
- Additional egress protocols (HTTPS, custom TCP, MQ)
- ZPA-based patterns (internal SFTP destinations)
- Multi-AZ Lambda configurations
- Terraform provider `zscaler/ziapi` integration (current scripts use raw OneAPI)

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).

## Disclaimer

Reference implementation. Zscaler provides no warranty. Customers deploying into regulated environments must complete their own threat modelling and apply their organizational controls (KMS CMKs, VPC endpoints, SCPs, private-subnet egress, WAF/IDS overlays, etc.) before production use.
