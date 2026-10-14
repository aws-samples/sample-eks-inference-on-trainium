################################################################################
# Model bootstrapping - S3 access for the model pods, and the model weights in S3:
#   1. Model storage access: S3 IAM + Pod Identity for the model-uploader
#      (read/write) and model-reader (read-only) ServiceAccounts.
#   2. Model weights: one model-weights-<model> Job per var.models entry
#      (HuggingFace -> S3, once).
#   3. Image warmers: pre-pull the vLLM and Ray serving images onto accelerator nodes.
# Kubernetes objects are plain YAML under ./manifests (rendered with templatefile).
################################################################################

################################################################################
# 1. Model storage access
#
# model-uploader (S3 read/write): the weights, compile and benchmark Jobs. model-reader
# (S3 read-only): every serving pod's init container pulls the model dir to NVMe.
# Both via EKS Pod Identity, not the node role / IMDS.
################################################################################

# IAM policy: read/write the model cache bucket
resource "aws_iam_policy" "model_uploader_s3" {
  name        = "${local.name}-model-uploader-s3"
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
  yaml_body         = file("${path.module}/manifests/model-uploader-serviceaccount.yaml")
  depends_on        = [module.eks]
}

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
  yaml_body         = file("${path.module}/manifests/model-reader-serviceaccount.yaml")
  depends_on        = [module.eks]
}

################################################################################
# 2. Model weights -> S3 (one-time setup)
#
# model-weights-<model> Jobs (one per var.models entry) download the upstream
# weights from HuggingFace once, upload them to s3://<bucket>/<model>/, then write
# the <model>/.ready/weights marker that the compile and serving pods wait on.
#
# Layout (same everywhere - S3 mirrors the node-local NVMe dir):
#   s3://<bucket>/<model>/        <->  /tmp/models/<model>/        MODEL_ID (weights)
#   s3://<bucket>/<model>/cache/  <->  /tmp/models/<model>/cache/  VLLM_CACHE_ROOT
#   s3://<bucket>/benchmarks/                                      benchmark results
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
    module.model_uploader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    aws_s3_bucket.model_storage
  ]
}

################################################################################
# 3. Image warmers
#
# One DaemonSet per hardware that pre-pulls its multi-GB serving images from ECR
# onto every node of that hardware as soon as the node joins - vllm-neuron +
# ray-neuron on Neuron nodes, vllm-gpu + ray-gpu on GPU nodes - so compile,
# serving and Ray pods start from a cached image. One sleeping container per
# image; the value is the image pull kubelet does to run it (later pods reuse it
# via IfNotPresent). Each Ray image is built FROM its vLLM image, so the second
# pull only adds the Ray layers.
################################################################################

resource "kubectl_manifest" "image_warmer" {
  for_each = {
    neuron = { node_label = "neuron.amazonaws.com/neuron-device" }
    gpu    = { node_label = "nvidia.com/gpu" }
  }

  server_side_apply = true
  # Don't block the apply on the rollout: nodes come and go with Karpenter.
  wait_for_rollout = false
  yaml_body = templatefile("${path.module}/manifests/image-warmer-daemonset.yaml", {
    name = "image-warmer-${each.key}"
    images = [
      "${aws_ecr_repository.vllm[each.key].repository_url}:${local.vllm_image_tags[each.key]}",
      "${aws_ecr_repository.ray[each.key].repository_url}:${local.ray_image_tags[each.key]}",
    ]
    node_label = each.value.node_label
  })
  depends_on = [module.eks]
}
