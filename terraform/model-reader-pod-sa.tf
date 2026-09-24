################################################################################
# Read-only S3 access for serving/deployment pods (model-reader SA)
#
# All workshop serving manifests (vLLM, RayService, RAG, agents, observability)
# set `serviceAccountName: model-reader` so their init container can pull the
# model from the S3 cache to local NVMe. Read-only; the write path (pull job)
# uses the separate model-uploader SA.
################################################################################

resource "aws_iam_policy" "model_reader_s3" {
  name        = "${local.name}-model-reader-s3"
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
        Resource = aws_s3_bucket.model_storage.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.model_storage.arn}/*"
      }
    ]
  })
}

module "model_reader_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "model-reader"

  additional_policy_arns = {
    S3 = aws_iam_policy.model_reader_s3.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "default"
      service_account = "model-reader"
    }
  }

  tags = local.tags
}

resource "kubectl_manifest" "model_reader_sa" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: model-reader
      namespace: default
  YAML
  depends_on        = [module.eks]
}
