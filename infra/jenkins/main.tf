# Jenkins controller on EC2 for the expand/contract PoC.
#
#   cd infra/jenkins
#   terraform init
#   terraform apply             # needs infra/aws applied first (looks up its RDS + security group)
#   terraform destroy           # stops all charges; RDS is untouched
#
# Creates: one small EC2 instance (Amazon Linux 2023) running Jenkins + Docker,
# port 8080 open to the admin IP only, no SSH (shell via SSM Session Manager),
# an instance role that may read the RDS master secret, and a rule letting the
# instance reach RDS on 5432 from inside the VPC (no per-run port opening).
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
      Component = "jenkins"
    }
  }
}

data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = coalesce(var.admin_cidr, "${chomp(try(data.http.my_ip[0].response_body, ""))}/32")
}

# ------------------------------------------------------- existing RDS stack
data "aws_db_instance" "poc" {
  db_instance_identifier = var.db_instance
}

data "aws_security_group" "db" {
  id = one(data.aws_db_instance.poc.vpc_security_groups)
}

# ------------------------------------------------------------------ network
data "aws_vpc" "default" {
  default = true
}

# Not every AZ offers every instance type: pick a default subnet in one that does.
data "aws_ec2_instance_type_offerings" "here" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.here.locations
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "jenkins" {
  name        = "${var.name}-jenkins"
  description = "Jenkins UI for the expand/contract PoC; admin IP only. No SSH: use SSM Session Manager."
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "ui" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Jenkins UI from admin workstation"
  cidr_ipv4         = local.admin_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.jenkins.id
  description       = "packages, GitHub, Docker Hub, AWS APIs, RDS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Jenkins -> RDS inside the VPC (the RDS endpoint resolves to its private IP here).
resource "aws_vpc_security_group_ingress_rule" "db_from_jenkins" {
  security_group_id            = data.aws_security_group.db.id
  description                  = "Jenkins controller"
  referenced_security_group_id = aws_security_group.jenkins.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# --------------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.name}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "rds_access" {
  statement {
    sid       = "DescribeDb"
    actions   = ["rds:DescribeDBInstances"]
    resources = [data.aws_db_instance.poc.db_instance_arn]
  }
  statement {
    sid       = "ReadMasterPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_db_instance.poc.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "rds_access" {
  name   = "rds-access"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.rds_access.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name}-jenkins"
  role = aws_iam_role.jenkins.name
}

# ---------------------------------------------------------------- instance
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  associate_public_ip_address = true
  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets Docker containers reach the instance role too
  }

  credit_specification {
    cpu_credits = "standard" # never bill for CPU bursting beyond earned credits
  }

  lifecycle {
    ignore_changes = [ami] # a newer AL2023 image must not replace a configured Jenkins
  }

  tags = { Name = "${var.name}-jenkins" }
}
