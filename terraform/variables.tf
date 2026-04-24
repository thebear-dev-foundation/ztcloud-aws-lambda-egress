variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-southeast-2"
}

variable "vpc_id" {
  description = "VPC where the Lambda egress subnet will be created. The VPC must already have Zscaler Cloud Connectors + GWLB endpoints deployed."
  type        = string
}

variable "route_table_id" {
  description = "Existing route table to associate the new subnet with. Must direct 0.0.0.0/0 (or the SFTP destination) through the Cloud Connector GWLBe."
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for the new Lambda egress subnet. Must be a free block within the VPC's CIDR. A /28 (11 usable IPs) is sufficient for a single Lambda."
  type        = string
}

variable "availability_zone" {
  description = "AZ where the subnet is created."
  type        = string
}

variable "sftp_host" {
  description = "SFTP server hostname or IP the Lambda will connect to."
  type        = string
}

variable "sftp_port" {
  description = "SFTP port."
  type        = number
  default     = 22
}

variable "sftp_user" {
  description = "SFTP username."
  type        = string
}

variable "sftp_password" {
  description = "SFTP password. In production, read from an external secret source, not tfvars. Marked sensitive so it doesn't appear in plan output."
  type        = string
  sensitive   = true
}

variable "egress_profile_tag" {
  description = "AWS tag value identifying this Lambda's egress profile. Applied to the subnet for audit + Zscaler WDS discovery."
  type        = string
  default     = "sftp"
}

variable "workload_group_tag" {
  description = "AWS tag value used by Zscaler Workload Groups (via WDS) to reference this subnet in policy."
  type        = string
  default     = "sftp-egress"
}

variable "lambda_name" {
  description = "Lambda function name."
  type        = string
  default     = "ztw-lambda-sftp-egress"
}

variable "test_mode" {
  description = "Runtime mode for the Lambda. 'tcp' performs a TCP connect to sftp_host:sftp_port only (smoke test, no creds needed). 'sftp' performs full SFTP LIST + upload (requires paramiko layer + sftp creds)."
  type        = string
  default     = "sftp"
  validation {
    condition     = contains(["tcp", "sftp"], var.test_mode)
    error_message = "test_mode must be 'tcp' or 'sftp'."
  }
}

variable "lambda_zip_path" {
  description = "Path to the pre-built Lambda deployment zip (built by scripts/build-lambda.sh)."
  type        = string
  default     = "lambda/build/lambda.zip"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda."
  type        = number
  default     = 365
}

variable "secret_name" {
  description = "Secrets Manager secret name storing the SFTP credentials."
  type        = string
  default     = "ztw-lambda-sftp/credentials"
}
