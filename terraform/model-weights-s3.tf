################################################################################
# Model weights -> S3 (one-time setup)
#
# model-weights-<model> Jobs (one per var.models entry) download the upstream
# weights from HuggingFace once and upload them to s3://<bucket>/<model>/, then
# write the <model>/.ready/weights
# marker. Markers live under <model>/.ready/ (also .ready/cache/<image-tag>/<profile>
# for platform compile Jobs).
#
# Layout (same everywhere - S3 mirrors the node-local NVMe dir):
#   s3://<bucket>/<model>/        <->  /tmp/models/<model>/        MODEL_ID (weights)
#   s3://<bucket>/<model>/cache/  <->  /tmp/models/<model>/cache/  VLLM_CACHE_ROOT
#   s3://<bucket>/benchmarks/                                      benchmark results
#
# Everything after that - serving profiles and per-profile compile Jobs - is
# the platform-charts/serving-platform release (serving-platform.tf), which gets
# the same S3 paths from these locals.
#
# Auth uses EKS Pod Identity (model-uploader SA), not the node role / IMDS. The
# compile Jobs in the platform chart reuse the same SA.
################################################################################

# Serving-platform model (var.model_name); the weights Jobs below cover every
# model in var.models with the same layout.
locals {
  s3_model_uri         = "s3://${local.s3_bucket_name}/${var.model_name}"
  s3_weights_ready_uri = "${local.s3_model_uri}/.ready/weights"
}

# IAM policy: read/write the model cache bucket
resource "aws_iam_policy" "model_uploader_s3" {
  name        = "${local.name}-model-uploader-s3"
  description = "Allows the model-compile-s3 job to read/write the model cache bucket."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.model_storage.arn
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
        Resource = "${aws_s3_bucket.model_storage.arn}/*"
      }
    ]
  })
}

# Pod Identity association for the uploader service account
module "model_uploader_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "model-uploader"

  additional_policy_arns = {
    S3 = aws_iam_policy.model_uploader_s3.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "default"
      service_account = "model-uploader"
    }
  }

  tags = local.tags
}

resource "kubectl_manifest" "model_uploader_sa" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: model-uploader
      namespace: default
  YAML
  depends_on        = [module.eks]
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
    s3_model_uri         = "s3://${local.s3_bucket_name}/${each.key}"
    s3_weights_ready_uri = "s3://${local.s3_bucket_name}/${each.key}/.ready/weights"
  })
  depends_on = [
    kubectl_manifest.karpenter,
    module.karpenter,
    module.model_uploader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    aws_s3_bucket.model_storage
  ]
}

moved {
  from = kubectl_manifest.job_model_weights_s3
  to   = kubectl_manifest.job_model_weights_s3["gpt-oss-20b"]
}
