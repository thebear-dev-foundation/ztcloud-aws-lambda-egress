terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

data "aws_vpc" "target" { id = var.vpc_id }

# ========== Dedicated subnet for Lambda egress ==========
resource "aws_subnet" "lambda_egress" {
  vpc_id            = var.vpc_id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                     = "lambda-${var.egress_profile_tag}-egress"
    "zscaler-egress-profile" = var.egress_profile_tag
    "workload-group"         = var.workload_group_tag
    "managed-by"             = "ztcloud-aws-lambda-egress"
  }
}

resource "aws_route_table_association" "lambda_egress" {
  subnet_id      = aws_subnet.lambda_egress.id
  route_table_id = var.route_table_id
}

# ========== Security Group — egress restricted to SFTP destination ==========
resource "aws_security_group" "lambda_egress" {
  name        = "lambda-${var.egress_profile_tag}-egress"
  description = "Lambda ${var.egress_profile_tag} egress SG (narrowed by route+Zscaler policy)"
  vpc_id      = var.vpc_id

  tags = {
    Name                     = "lambda-${var.egress_profile_tag}-egress"
    "zscaler-egress-profile" = var.egress_profile_tag
  }
}

resource "aws_security_group_rule" "egress_sftp" {
  security_group_id = aws_security_group.lambda_egress.id
  type              = "egress"
  from_port         = var.sftp_port
  to_port           = var.sftp_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "SFTP egress (narrowed by route + Zscaler policy)"
}

# DNS resolution for Lambda (the default VPC DNS resolver lives at VPC+2, reachable from any subnet)
resource "aws_security_group_rule" "egress_dns" {
  security_group_id = aws_security_group.lambda_egress.id
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS for sftp_host FQDN resolution"
}

# ========== Lambda IAM role — least privilege ==========
resource "aws_iam_role" "lambda" {
  name = "${var.lambda_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "read_secret" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.sftp.arn
    }]
  })
}

# ========== SFTP credentials secret ==========
resource "aws_secretsmanager_secret" "sftp" {
  name        = var.secret_name
  description = "SFTP credentials for ${var.lambda_name}. Rotate per customer policy. Production: encrypt with CMK."
}

resource "aws_secretsmanager_secret_version" "sftp" {
  secret_id = aws_secretsmanager_secret.sftp.id
  secret_string = jsonencode({
    host     = var.sftp_host
    port     = var.sftp_port
    username = var.sftp_user
    password = var.sftp_password
  })
}

# ========== Lambda function ==========
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.lambda_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "sftp" {
  function_name    = var.lambda_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 60
  memory_size      = 256
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  vpc_config {
    subnet_ids         = [aws_subnet.lambda_egress.id]
    security_group_ids = [aws_security_group.lambda_egress.id]
  }

  environment {
    variables = {
      TEST_MODE   = var.test_mode
      SECRET_NAME = aws_secretsmanager_secret.sftp.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.basic_exec,
    aws_iam_role_policy_attachment.vpc_access,
    aws_iam_role_policy.read_secret,
    aws_secretsmanager_secret_version.sftp,
  ]
}
