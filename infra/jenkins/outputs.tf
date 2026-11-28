output "jenkins_url" {
  value = "http://${aws_instance.jenkins.public_dns}:8080"
}

output "instance_id" {
  value = aws_instance.jenkins.id
}

output "admin_cidr" {
  value = local.admin_cidr
}

output "initial_admin_password_command" {
  description = "Prints the one-time unlock password via SSM (no SSH needed)."
  value       = "scripts/setup/jenkins-unlock.sh"
}

output "shell_command" {
  description = "Interactive shell on the instance (needs the AWS CLI Session Manager plugin)."
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.region}"
}
