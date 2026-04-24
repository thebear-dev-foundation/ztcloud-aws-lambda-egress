# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-24

### Added
- AWS-side Terraform: dedicated subnet, security group, VPC-attached Lambda, IAM role, Secrets Manager secret for SFTP creds.
- Lambda SFTP client (paramiko) with TCP-connect fallback for smoke testing.
- Zscaler-side deploy script using OneAPI: ZIA IP Source Group, Network Service, Firewall Filtering rule, Cloud Connector forwarding rule, activation.
- Architecture + risk-review document.
- End-to-end test harness.

### Not yet implemented
- Customer-managed KMS key for the SFTP secret.
- VPC endpoints for AWS service calls from Lambda (Secrets Manager, STS).
- Terraform zscaler/ziapi provider integration (scripts currently use raw OneAPI).
- ZPA path for internal SFTP destinations.
- Multi-AZ / redundant subnet deployment.
