output "cluster_name"       { value = module.eks.cluster_name }
output "ecr_url"            { value = aws_ecr_repository.app.repository_url }
output "secrets_arn"        { value = aws_secretsmanager_secret.app_config.arn }
output "jenkins_role_arn"   { value = aws_iam_role.jenkins.arn }
output "kubeconfig_command" { value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}" }
