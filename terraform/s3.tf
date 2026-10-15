################################################################################
# S3 Bucket for Model Storage
#
# Created here unless var.existing_cache_bucket names a bucket to reuse (weights,
# compile cache and results from an earlier cluster). An existing bucket is only
# read via the data source: Terraform never modifies or deletes it.
################################################################################

data "aws_s3_bucket" "existing_cache" {
  count  = local.create_bucket ? 0 : 1
  bucket = var.existing_cache_bucket
}

resource "aws_s3_bucket" "model_storage" {
  count = local.create_bucket ? 1 : 0

  bucket        = local.s3_bucket_name
  force_destroy = true

  tags = merge(local.tags, {
    Name        = local.s3_bucket_name
    Purpose     = "ML Model Storage"
    Environment = "workshop"
    CostCenter  = local.name
  })
}

# Configure bucket versioning
resource "aws_s3_bucket_versioning" "model_storage" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.model_storage[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configure server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "model_storage" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.model_storage[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "model_storage" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.model_storage[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Configure lifecycle policy
resource "aws_s3_bucket_lifecycle_configuration" "model_storage" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.model_storage[0].id

  rule {
    id     = "model_storage_lifecycle"
    status = "Enabled"

    # Transition to Infrequent Access after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Clean up incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# S3 gateway VPC endpoint: nodes in the private subnets reach S3 (weights,
# compile cache, benchmark results) over the AWS network instead of the NAT
# gateway - faster model pulls and no NAT data-processing charges. Gateway
# endpoints are free; the AWS CLI picks it up automatically via the route tables.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)

  tags = merge(local.tags, { Name = "${local.name}-s3" })
}
