variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Identifier prefix for all resources."
  type        = string
  default     = "liquibase-poc"
}

variable "db_instance" {
  description = "RDS instance identifier created by infra/aws."
  type        = string
  default     = "liquibase-poc"
}

variable "instance_type" {
  description = "t3.micro (1 GB, free-tier eligible) works with swap but is slow; t3.small (2 GB) is noticeably smoother."
  type        = string
  default     = "t3.micro"
}

variable "disk_gb" {
  description = "Root volume; 30 GB is the free-tier EBS allowance."
  type        = number
  default     = 30
}

variable "admin_cidr" {
  description = "CIDR allowed to open the Jenkins UI (e.g. 203.0.113.7/32). Null = this machine's current public IP."
  type        = string
  default     = null
}
