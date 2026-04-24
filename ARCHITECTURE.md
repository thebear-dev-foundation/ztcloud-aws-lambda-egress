# AWS Lambda → Zscaler Egress — Architecture, Identifier Strategy, Risk Review

**Status:** Reference implementation
**Classification:** PUBLIC — safe to share with customers and prospects
**Version:** 0.1.0
**Last updated:** 2026-04-24
**Target audience:** Customer cloud team, network architecture, security/risk review

---

## 1. Problem statement

A workflow requires an AWS Lambda function to make outbound connections to an external destination (SFTP server, third-party API, custom TCP service). The security posture requires:

1. **All Lambda egress is inspected by Zscaler** (Cloud Connector + ZIA), not direct-to-internet.
2. **Policy allows only this specific Lambda** to reach the specific destination on the specific protocol/port.
3. **The identifier tying the Lambda to the policy rule is auditable** — the rule must name something concrete that an auditor can verify ties back to this Lambda.

## 2. The central constraint: what Zscaler can and can't see

Zscaler's enforcement points — Cloud Connector, ZIA Firewall, ZIA URL Filtering, ZIA SSL Inspection — all operate on packet-level metadata and the application-layer content of the traffic. They do NOT have visibility into AWS control-plane metadata.

### 2.1 Identifier visibility matrix

| Identifier | Visible to Cloud Connector? | Visible to ZIA? | Why / why not |
|---|---|---|---|
| Lambda function ARN | ❌ | ❌ | Lambda function identity is AWS control-plane metadata, not carried in packets |
| Lambda execution IAM role | ❌ | ❌ | STS is internal to AWS; no token is sent outbound from the Lambda ENI for the egress connection |
| AWS resource tag on the Lambda function itself | ❌ | ❌ | AWS tags are metadata; Zscaler doesn't introspect AWS APIs in the data plane |
| AWS account ID | Partially (CC knows it) | ❌ | CC knows which account the GWLBe lives in, but ZIA sees only the post-GENEVE-decap packet — source is the ENI IP |
| Source IP (ENI IP) | ✅ | ✅ | The ENI IP is in every IP header; falls within the subnet CIDR |
| Source VPC subnet CIDR | ✅ | ✅ | Derived from source IP; stable for the life of the subnet |
| AWS resource tag on the VPC subnet | ⚠️ (only via WDS) | ⚠️ (only via WDS) | If Zscaler Workload Discovery Service is enabled, subnet tags are synchronized into Workload Groups that can be referenced in policy |
| Destination FQDN | ✅ (for DNS-inspection flows) | ✅ | ZIA resolves FQDN for matching; useful for "what they're talking to," not "who is talking" |

### 2.2 The only robust identifier is the subnet CIDR

The above matrix collapses to a single truth: **for per-Lambda policy, the identifier must be the dedicated subnet CIDR**. Every other identifier is either invisible to Zscaler or requires the optional WDS sync layer (which itself derives from subnet metadata).

This module therefore builds around a **1 Lambda ↔ 1 subnet ↔ 1 Zscaler identifier** alignment.

---

## 3. Solution architecture

### 3.1 Network path

```
Lambda function (VpcConfig pinned)
  │
  ▼
ENI in dedicated subnet 10.x.y.z/28   ← the identifier
  │      (tags: zscaler-egress-profile=sftp, workload-group=sftp-egress)
  │
  ▼
Route table (existing, customer-owned)
  │      default route: 0.0.0.0/0 → GWLBe
  ▼
Cloud Connector GWLBe (existing)
  │
  ▼
Cloud Connector
  │      forwarding rule: srcIps=subnet-CIDR, dest=sftp-host → forwardMethod=ZIA
  ▼
ZIA
  │      IP Source Group = subnet CIDR
  │      Firewall Filtering rule: srcIpGroups=[IP Source Group], dest=sftp-host,
  │                               nwService=SSH (or custom port), action=ALLOW
  │      SSL Inspection: typically BYPASS for SFTP-over-SSH (not HTTPS)
  ▼
SFTP server (internet)
```

### 3.2 Components delivered by this module

| # | Component | Layer |
|---|---|---|
| 1 | Dedicated VPC subnet (customer VPC) | AWS |
| 2 | Subnet tags (`zscaler-egress-profile`, `workload-group`) | AWS |
| 3 | Subnet route-table association (existing RT → Cloud Connector GWLBe) | AWS |
| 4 | Security group (egress: tcp/22 to SFTP destination, udp/53 to VPC resolver) | AWS |
| 5 | Lambda function (VPC-attached, paramiko SFTP client) | AWS |
| 6 | Lambda IAM role (CloudWatch Logs, Secrets Manager scoped to one ARN, VPC access managed policy) | AWS |
| 7 | Secrets Manager secret (SFTP credentials) | AWS |
| 8 | CloudWatch Logs group (configurable retention) | AWS |
| 9 | ZIA IP Source Group (holds the subnet CIDR) | Zscaler |
| 10 | ZIA Network Service (built-in SSH for port 22; Custom for non-22) | Zscaler |
| 11 | ZIA Firewall Filtering rule (ALLOW srcIpGroup → SFTP host on SSH/custom service) | Zscaler |
| 12 | Cloud Connector Forwarding rule (srcIps=subnet-CIDR, dest=SFTP host, forwardMethod=ZIA) | Zscaler |
| 13 | ZIA + CC activation calls | Zscaler |

Not delivered (customer-provided / out of scope):
- VPC itself
- Route table / GWLBe (existing Zscaler CC infrastructure)
- CMK for Secrets Manager (production should add one)
- VPC endpoints for AWS services (production should add for Secrets Manager, STS)
- ZIA SSL Inspection bypass rule (out of scope; SFTP-over-SSH is not inspectable)
- SCP locking the Lambda's VpcConfig to this subnet (customer org policy)

### 3.3 Defense in depth

The design assumes **no single enforcement point is sufficient**. Policy agreement between layers is what makes the control auditable:

| Layer | What it enforces |
|---|---|
| AWS IAM | Only the named Lambda role can run this function |
| AWS SCP (customer-owned) | Deny `lambda:UpdateFunctionConfiguration` that changes `VpcConfig` away from the approved subnet |
| AWS VPC route table | Traffic from the subnet is forced through the Cloud Connector GWLBe (no IGW route) |
| AWS Security Group | Egress limited to tcp/22 to SFTP destination + udp/53 for DNS |
| AWS NACL (optional, customer-owned) | Same as SG but stateless and applied to subnet |
| Zscaler Cloud Connector forwarding rule | Subnet CIDR is steered into ZIA inspection |
| Zscaler ZIA Firewall rule | Only the specific destination + service is allowed |
| Zscaler SSL Inspection (where applicable) | Bypass for SFTP (SSH-based, not decryptable); HTTPS destinations decrypted |
| Zscaler Web Insights / Firewall logs | Full flow telemetry forwarded to customer SIEM |

A compromise at any single layer is contained by the next.

---

## 4. Identifier strategy — recommended pattern

### 4.1 Base: subnet CIDR as IP Source Group

This is the default and the only required identifier. It works without any optional Zscaler feature.

**Pros**: Deterministic, auditor-friendly, survives IAM role changes, simple to write in a Zscaler FW rule.
**Cons**: If the subnet CIDR changes (VPC refactor), the rule must be updated.

### 4.2 Optional: Workload Group via Zscaler Workload Discovery Service

If the customer has WDS enabled and their subnet carries a matching tag, Zscaler's Workload Groups can reference the tag directly. Policy then follows the tag, not the IP.

**Pros**: Subnet CIDR changes don't break the rule. Tag-based policy is higher-abstraction.
**Cons**: Requires WDS deployment + discovery-role IAM. Adds one layer of "where is this tag coming from" that auditors may want to trace.

### 4.3 Optional: EC Group / Location-based policy

Steer the subnet's traffic through a named CC group or tag it with a specific ZIA Location. Write ZIA rules by Location.

**Pros**: Coarser — "all traffic from this path goes through this Location" — good for multi-subnet aggregation.
**Cons**: Less precise per Lambda; couples network routing to policy enumeration.

### 4.4 What the customer should NOT attempt

- **IAM role-based ZIA policy** — not possible. ZIA has no visibility into AWS STS.
- **Lambda tag-based ZIA policy** — not possible. Tags on Lambda functions are not propagated to Zscaler.
- **SNI-based policy for SFTP** — not possible. SFTP is SSH, not TLS; there is no SNI.

---

## 5. Security model

### 5.1 Trust boundaries

| Boundary | Control | Enforcement |
|---|---|---|
| AWS account boundary | IAM role ARN bound to this Lambda only | AWS IAM |
| VPC boundary | Subnet CIDR separated from other workloads; dedicated Security Group | AWS VPC, SG |
| AWS ⇄ internet | All egress via Cloud Connector + ZIA inspection | Route table + CC forwarding rule |
| Lambda ⇄ SFTP server | Zscaler FW rule; payload inspection bypassed (SSH), identified by source IP group + destination + service | ZIA FW |

### 5.2 Secrets handling

**Current:** SFTP credentials stored in Secrets Manager using the AWS-managed key (`aws/secretsmanager`). Lambda fetches at invocation time via the secret ARN.

**Production hardening required:**
1. Create a customer-managed KMS key (CMK) in the same account.
2. Encrypt the secret with the CMK.
3. KMS key policy grants `Decrypt` only to the Lambda role.
4. Enable Secrets Manager automatic rotation with a customer-written rotation Lambda (SFTP servers vary — rotation is SFTP-specific and out of this module's scope).
5. Route Secrets Manager calls via a VPC endpoint to avoid transit over public internet.

### 5.3 Network egress hardening

In this reference module the Lambda is VPC-attached with egress routed through the existing Cloud Connector GWLBe. Additional production hardening:

- **VPC endpoints** for `secretsmanager`, `sts`, `logs`, `kms`, and `ec2` (for ENI management). Ensures all AWS-service calls go AWS-internal, not out-and-back via internet.
- **NACL** on the subnet: explicit allow outbound tcp/22 + udp/53; deny everything else.
- **DNS firewall** (Route 53 Resolver DNS Firewall) to constrain which FQDNs the Lambda can resolve.

### 5.4 Data classification

| Data | Location | Classification | Notes |
|---|---|---|---|
| SFTP password | Secrets Manager | SECRET | CMK-encrypted in production; rotated per customer policy |
| SFTP username | Secrets Manager + Lambda env at invocation | CONFIDENTIAL | — |
| SFTP destination FQDN/IP | Terraform vars + Lambda env + Zscaler policy | INTERNAL | — |
| Subnet CIDR | Terraform vars + tags + Zscaler IP Source Group | INTERNAL | — |
| File contents uploaded via SFTP | SFTP server + VPC Flow Logs (sizes only) | per-payload (customer-defined) | Contents not captured by this module |
| Lambda logs | CloudWatch Logs | INTERNAL | Avoid logging credentials or payload contents |

---

## 6. Risk register

| # | Risk | Likelihood | Impact | Mitigation | Residual |
|---|---|---|---|---|---|
| R1 | Lambda re-associated to a different subnet (bypassing Zscaler policy) | Low | High | SCP denying `lambda:UpdateFunctionConfiguration` changing `VpcConfig.SubnetIds`; Config rule checking assignment; Security Group still blocks egress broadly | Low |
| R2 | Security Group widened to allow unrelated egress | Low | High | Terraform drift detection; Config rule; IAM boundary preventing SG rule additions | Low |
| R3 | SFTP credentials leak (from logs or memory dump) | Low | High | No env-var passing of password; Secrets Manager only; CMK encryption; no payload logging; log retention bounded | Low |
| R4 | Zscaler FW rule widened (source group extended, action changed) | Low | Medium | OneAPI CloudTrail audit on Zscaler side; policy-as-code (this module) with drift detection; ZIA admin-user separation | Medium |
| R5 | Lambda executes unintended SSH commands (exec-mode rather than SFTP) | Medium | Medium | Destination service scoped; SFTP server-side policy restricts user shell | Customer-dependent |
| R6 | CC forwarding rule not activated after creation | Medium | Medium | `deploy-zscaler-policy.sh` always calls activation endpoint; verify `orgEditStatus != EDITS_PRESENT` post-deploy | Low |
| R7 | DNS poisoning redirects Lambda to attacker SFTP server | Low | Medium | VPC resolver forced via SG; DNS firewall whitelisting known FQDNs; Lambda pinned to FQDN or IP | Low |
| R8 | Paramiko vulnerability | Medium | Medium | Pin paramiko version in requirements.txt; monitor Zscaler ThreatLabz + CVE feeds; bump and redeploy | Low |
| R9 | Zscaler tenant compromise | Low | High | Customer-side compensating controls (MFA, role separation); Zscaler's own operational controls | External |
| R10 | SFTP server impersonation (host key not verified) | Medium | Medium | **This reference code does not verify SFTP host keys** (paramiko `AutoAddPolicy` by default). Customer must replace with `RejectPolicy` + known-hosts file in production | Customer-owned |

**Explicit caveat — R10:** the reference handler uses paramiko's default which accepts any host key on first connect. For production, configure known-host pinning. See `terraform/lambda/handler.py` and replace `_sftp_test` accordingly before deploying against a real SFTP server.

---

## 7. Compliance mapping (summary)

| Framework | Addressed by |
|---|---|
| NIST CSF — ID.AM | Subnet tagging; Secrets Manager inventory |
| NIST CSF — PR.AC | Lambda IAM role least-privilege; SG restricted egress |
| NIST CSF — PR.DS | Secrets Manager encryption; TLS to AWS services; CC + ZIA inspection |
| NIST CSF — DE.CM | CloudWatch Logs + ZIA Web Insights + VPC Flow Logs |
| CIS AWS — 2.4 | CloudWatch log group present + retention |
| CIS AWS — 4.x | Network egress via Zscaler; SG restricted |
| ISO 27001 — A.8.3 | Role-based access; Secret-scoped permissions |
| ISO 27001 — A.8.21 | TLS everywhere; ZIA FW governance of egress |
| SOC 2 — CC6.1 | Logical access controls at IAM + ZIA layers |
| SOC 2 — CC7.2 | Monitoring via CloudWatch + ZIA logs |

---

## 8. Operations runbook

### 8.1 Deploy

```bash
cp .env.example .env    # populate ZS + SFTP creds
./scripts/build-lambda.sh
./scripts/deploy.sh --vpc-id <...> --route-table-id <...> --subnet-cidr <...> --availability-zone <...>
./scripts/deploy-zscaler-policy.sh
./scripts/test.sh
```

### 8.2 Rotate SFTP credentials

Update the secret (either via Secrets Manager console or `aws secretsmanager put-secret-value`). Lambda picks up new value on next cold start; force with:
```bash
aws lambda update-function-configuration --function-name ztw-lambda-sftp-egress \
  --environment "Variables={TEST_MODE=sftp,SECRET_NAME=ztw-lambda-sftp/credentials,FORCE_RELOAD=$(date +%s)}"
```

### 8.3 Break-glass

If the Lambda is misbehaving:
```bash
# Throttle to zero (stop all invocations)
aws lambda put-function-concurrency --function-name ztw-lambda-sftp-egress \
  --reserved-concurrent-executions 0

# Or disable the Zscaler FW rule (source-side hard block)
curl -s -X PUT "https://api.zsapi.net/zia/api/v1/firewallFilteringRules/<id>" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"state":"DISABLED", ...}'
curl -s -X POST https://api.zsapi.net/zia/api/v1/status/activate \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"status":"ACTIVE"}'
```

### 8.4 Teardown

```bash
./scripts/cleanup.sh
```

Deletes Zscaler rules (via OneAPI), then `terraform destroy` the AWS side.

---

## 9. Appendices

### A. OneAPI endpoints used

| Endpoint | Method | Purpose |
|---|---|---|
| `/oauth2/v1/token` (on vanity domain) | POST | OAuth2 token exchange |
| `/zia/api/v1/ipSourceGroups` | GET, POST, PUT, DELETE | IP Source Groups |
| `/zia/api/v1/networkServices` | GET, POST | Network Services (custom ports) |
| `/zia/api/v1/firewallFilteringRules` | GET, POST, PUT, DELETE | ZIA FW rules |
| `/zia/api/v1/status/activate` | POST | Activate ZIA changes |
| `/ztw/api/v1/ecRules/ecRdr` | GET, POST, PUT, DELETE | CC forwarding rules |
| `/ztw/api/v1/ecAdminActivateStatus/activate` | PUT | Activate CC changes |

**Rate limit:** OneAPI caps at 1 request/second. Scripts in this module serialize with 2-second sleeps between calls.

### B. Packaging paramiko for Lambda

Lambda's runtime is Linux x86_64. paramiko depends on `cryptography` (Rust) and `cffi` (C) — both ship native extensions. Building on macOS arm64 without cross-compile flags produces a zip that will fail at import.

The `scripts/build-lambda.sh` uses pip's `--platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12` flags to fetch pre-built Linux x86_64 wheels from PyPI, avoiding any cross-compile step. Requires pip 22+.

### C. SFTP host-key verification (production TODO)

The reference handler uses `paramiko.Transport(...)` which does not verify the server's host key by default. In production:

```python
import paramiko
client = paramiko.SSHClient()
client.load_host_keys("/opt/known_hosts")  # bundle in Lambda layer
client.set_missing_host_key_policy(paramiko.RejectPolicy())
client.connect(hostname=host, port=port, username=user, password=password)
sftp = client.open_sftp()
```

Pin the SFTP server's host key into `known_hosts` at build time and bundle it in the Lambda package.

---

**END**
