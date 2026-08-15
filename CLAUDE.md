@~/.claude/CLAUDE.md

# This repo: ztcloud-aws-lambda-egress

Reference implementation for steering AWS Lambda egress traffic through Zscaler Cloud Connector + ZIA, using a subnet-based identifier so the customer's security team can write precise allow-list policy for a Lambda-hosted workflow. Worked example: SFTP egress (Lambda → external SFTP server). Pattern applies to any Lambda outbound traffic that needs Zscaler policy enforcement.

## Stack
- Terraform (`terraform/` — 3 .tf files)
- Bash (`scripts/`)
- AWS Lambda (the worked example workload — implementation lives in `terraform/`)
- Zscaler Cloud Connector + ZIA (the policy-enforcement plane — external)

## Structure
- `README.md` — problem + architecture + design (load-bearing)
- `ARCHITECTURE.md` — architecture deep-dive
- `CHANGELOG.md`, `LICENSE`
- `terraform/` — module entry point (3 .tf files)
- `scripts/` — operational helpers

## Conventions
- Per-Lambda subnet pattern: each Lambda that needs distinct policy gets its own VPC subnet, tagged, with the subnet CIDR used as the Zscaler policy anchor (either directly as an IP Source Group or via a Workload Group discovered by WDS).
- Source IP is the only network-observable identifier — IAM role / Lambda ARN / resource tags are NOT visible to Zscaler policy. Do not write docs that suggest otherwise.

## Constraints
- The README's constraint section is load-bearing: ZIA and Cloud Connector see only packets, not AWS control-plane metadata. Any future "feature" that assumes Zscaler can see Lambda ARNs / IAM roles is wrong.
- This is a reference module — assume customers will copy/paste; keep examples honest.

## Entry points
- Read `README.md` then `ARCHITECTURE.md`.
- `terraform/` — module entry point.
- `scripts/` — operational helpers.
