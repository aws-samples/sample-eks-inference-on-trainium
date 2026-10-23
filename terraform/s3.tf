################################################################################
# Model storage in S3: the bucket (weights and benchmark results), its VPC
# endpoint, the s3-reader / s3-writer access, and the model-weights Jobs.
#
# The bucket is created here unless var.existing_cache_bucket names a bucket to reuse (weights,
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

################################################################################
# S3 access: s3-reader and s3-writer
#
# s3-writer (S3 read/write): the weights, compile and benchmark Jobs. s3-reader
# (S3 read-only): every serving pod's init container pulls the model dir to NVMe.
# Both via EKS Pod Identity, not the node role / IMDS.
################################################################################

# IAM policy: read/write the model cache bucket
resource "aws_iam_policy" "s3_writer" {
  name        = "${local.iam_name}-s3-writer"
  description = "Read/write the model bucket: weights Job, Neuron compile Jobs, benchmark Jobs."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = local.s3_bucket_arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${local.s3_bucket_arn}/*"
      }
    ]
  })
}

# Pod Identity association for the uploader service account
module "s3_writer_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "s3-writer"

  additional_policy_arns = {
    S3 = aws_iam_policy.s3_writer.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "default"
      service_account = "s3-writer"
    }
  }

  tags = local.tags
}

resource "kubectl_manifest" "s3_writer_sa" {
  server_side_apply = true
  yaml_body         = file("${path.module}/manifests/s3-writer-serviceaccount.yaml")
  depends_on        = [module.eks]
}

resource "aws_iam_policy" "s3_reader" {
  name        = "${local.iam_name}-s3-reader"
  description = "Read-only access to the model cache bucket for serving pods."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = local.s3_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.s3_bucket_arn}/*"
      }
    ]
  })
}

module "s3_reader_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "s3-reader"

  additional_policy_arns = {
    S3 = aws_iam_policy.s3_reader.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "default"
      service_account = "s3-reader"
    }
  }

  tags = local.tags
}

resource "kubectl_manifest" "s3_reader_sa" {
  server_side_apply = true
  yaml_body         = file("${path.module}/manifests/s3-reader-serviceaccount.yaml")
  depends_on        = [module.eks]
}

################################################################################
# Model weights -> S3 (one-time setup)
#
# model-weights-<model> Jobs (one per var.models entry) download the upstream
# weights from HuggingFace once, upload them to s3://<bucket>/<model>/, then write
# the <model>/.ready/weights marker that the compile and serving pods wait on.
#
# Layout (same everywhere - S3 mirrors the node-local NVMe dir):
#   s3://<bucket>/<model>/      <->  /tmp/models/<model>/   MODEL_ID (weights)
#   s3://<bucket>/benchmarks/                                benchmark results
# (the Neuron compile cache lives on EFS, see efs.tf)
#
################################################################################

# S3 paths per model (var.models).
locals {
  model_s3 = {
    for name, repo in var.models : name => {
      uri             = "s3://${local.s3_bucket_name}/${name}"
      weightsReadyUri = "s3://${local.s3_bucket_name}/${name}/.ready/weights"
    }
  }
}

# One model-weights-<model> Job per var.models entry. Jobs are immutable, so
# force_new recreates one when its rendered spec changes (e.g. a different repo).
resource "kubectl_manifest" "job_model_weights_s3" {
  for_each = var.models

  server_side_apply = true
  force_new         = true
  yaml_body = templatefile("${path.module}/manifests/model-weights-s3-job.yaml", {
    region               = local.region
    model_name           = each.key
    hf_repo_id           = each.value
    s3_model_uri         = local.model_s3[each.key].uri
    s3_weights_ready_uri = local.model_s3[each.key].weightsReadyUri
  })
  depends_on = [
    kubectl_manifest.karpenter,
    module.karpenter,
    module.s3_writer_pod_identity,
    kubectl_manifest.s3_writer_sa,
    aws_s3_bucket.model_storage,
    data.aws_s3_bucket.existing_cache
  ]
}

