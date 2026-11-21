output "endpoint" {
  value = aws_db_instance.poc.address
}

output "port" {
  value = aws_db_instance.poc.port
}

output "master_username" {
  value = aws_db_instance.poc.username
}

output "master_secret_arn" {
  description = "Secrets Manager secret holding the master password (JSON: username, password)."
  value       = aws_db_instance.poc.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.db.id
}

output "admin_cidr" {
  value = local.admin_cidr
}

output "github_ci_role_arn" {
  description = "Set as GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.github_ci.arn
}
