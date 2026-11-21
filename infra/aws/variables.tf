variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Identifier prefix for all resources."
  type        = string
  default     = "liquibase-poc"
}

variable "instance_class" {
  description = "db.t3.micro is burstable: fine for wiring and small runs; use a non-burstable class (e.g. db.m7g.large) for timed experiments."
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "Major version; AWS picks the current minor."
  type        = string
  default     = "16"
}

variable "storage_gb" {
  type    = number
  default = 20
}

variable "admin_cidr" {
  description = "CIDR allowed to reach PostgreSQL (e.g. 203.0.113.7/32). Null = this machine's current public IP."
  type        = string
  default     = null
}

variable "github_repo_with_ids" {
  description = "owner@owner_id/name@repo_id as GitHub puts it in the OIDC sub claim (see CloudTrail AssumeRoleWithWebIdentity events)."
  type        = string
  default     = "jim-otieno@63877969/liquibasepoc@1466400354"
}

variable "github_repo" {
  description = "owner/name of the repository whose main-branch workflows may use the database."
  type        = string
  default     = "jim-otieno/liquibasepoc"
}
