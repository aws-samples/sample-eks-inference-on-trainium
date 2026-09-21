################################################################################
# Outputs
################################################################################

output "model_storage_bucket" {
  description = "Name of the S3 bucket holding the model cache."
  value       = aws_s3_bucket.model_storage.bucket
}

output "model_storage_bucket_arn" {
  description = "ARN of the S3 model cache bucket."
  value       = aws_s3_bucket.model_storage.arn
}
