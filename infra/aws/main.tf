# RDS PostgreSQL target for the expand/contract PoC.
#
#   cd infra/aws
#   terraform init
#   terraform plan  -out tfplan
#   terraform apply tfplan
#   terraform destroy           # when not experimenting: stops all charges
#
# Creates: RDS PostgreSQL 16 (single-AZ, public endpoint, TLS forced),
# a security group open only to the admin's IP, a parameter group with lock
# logging, and an IAM role GitHub Actions on `main` can assume via OIDC to
# open the group to its runner for one CI run.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.70" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "liquibase-expand-contract-poc"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Admin IP: given explicitly, or detected from this machine.
data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = coalesce(var.admin_cidr, "${chomp(try(data.http.my_ip[0].response_body, ""))}/32")
}

# ------------------------------------------------------------------ network
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_db_subnet_group" "poc" {
  name       = "${var.name}-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL for the expand/contract PoC; admin IP only. CI adds and removes its runner IP per run."
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # CI adds temporary /32 rules at run time; do not let Terraform fight over them.
  lifecycle {
    ignore_changes = [ingress]
  }
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  security_group_id = aws_security_group.db.id
  description       = "admin workstation"
  cidr_ipv4         = local.admin_cidr
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

# ----------------------------------------------------------------- database
resource "aws_db_parameter_group" "poc" {
  name   = "${var.name}-pg16"
  family = "postgres16"

  # Log every lock wait longer than deadlock_timeout (1 s): a second lock measure.
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "poc" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "poc"
  username                    = "poc_admin"
  manage_master_user_password = true # password lives in Secrets Manager, never in state or git

  db_subnet_group_name   = aws_db_subnet_group.poc.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = true
  multi_az               = false
  parameter_group_name   = aws_db_parameter_group.poc.name

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Research PoC: easy teardown. Change both for anything holding real data.
  deletion_protection = false
  skip_final_snapshot = true
}

# ------------------------------------------------- GitHub Actions (OIDC)
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself; the thumbprint is required by the API but not used.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only workflows on the main branch of this repository - never pull requests or forks.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name                 = "${var.name}-github-ci"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_ci" {
  statement {
    sid       = "DescribeDb"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.poc.arn]
  }
  statement {
    sid       = "OpenCloseRunnerIp"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/${aws_security_group.db.id}"]
  }
  statement {
    sid       = "ReadMasterPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.poc.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "github_ci" {
  name   = "rds-ci-access"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci.json
}
