output "launcher_access_key_id" {
  value = aws_iam_access_key.launcher.id
}

output "launcher_secret_access_key" {
  value     = aws_iam_access_key.launcher.secret
  sensitive = true
}
