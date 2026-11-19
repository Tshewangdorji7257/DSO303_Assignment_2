output "site_url" { value = "https://${aws_cloudfront_distribution.main.domain_name}" }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.main.id }
output "frontend_bucket" { value = aws_s3_bucket.frontend.bucket }
output "uploads_bucket" { value = aws_s3_bucket.uploads.bucket }
output "ecr_repository_url" { value = aws_ecr_repository.api.repository_url }
output "db_identifier" { value = aws_db_instance.main.identifier }
output "cognito_user_pool_id" { value = aws_cognito_user_pool.main.id }
