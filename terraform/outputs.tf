output "subnet_id" {
  description = "Dedicated Lambda egress subnet ID."
  value       = aws_subnet.lambda_egress.id
}

output "subnet_cidr" {
  description = "Subnet CIDR — the identifier Zscaler policy is anchored on."
  value       = aws_subnet.lambda_egress.cidr_block
}

output "security_group_id" {
  description = "Security group restricting Lambda egress to SFTP destination."
  value       = aws_security_group.lambda_egress.id
}

output "lambda_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.sftp.function_name
}

output "lambda_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.sftp.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group for the Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "secret_arn" {
  description = "Secrets Manager secret holding SFTP credentials."
  value       = aws_secretsmanager_secret.sftp.arn
}

output "zscaler_policy_inputs" {
  description = "Inputs for the Zscaler-side deploy script (scripts/deploy-zscaler-policy.sh reads these via terraform output -json)."
  value = {
    subnet_cidr            = aws_subnet.lambda_egress.cidr_block
    sftp_host              = var.sftp_host
    sftp_port              = var.sftp_port
    egress_profile_tag     = var.egress_profile_tag
    workload_group_tag     = var.workload_group_tag
    ip_source_group_name   = "AWS-Lambda-${var.egress_profile_tag}-Egress"
    firewall_rule_name     = "Allow-Lambda-${var.egress_profile_tag}-Out"
    cc_forwarding_rule     = "Lambda-${var.egress_profile_tag}-To-ZIA"
  }
}
