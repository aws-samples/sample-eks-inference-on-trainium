################################################################################
# Model pull -> S3 (fast path, alternative to the FSx pull in pull.tf)
#
# Mirrors pull.tf's job, but instead of writing into an FSx PVC it:
#   1. Downloads the model from HuggingFace to local NVMe (emptyDir) using
#      huggingface_hub with the hf_xet backend (the aws-neuron repo is
#      Xet-backed -> hf_xet gives parallel chunked transfer; far faster than
#      the plain HTTP fallback the current genai:v6 image uses).
#   2. Uploads to S3 with AWS CLI v2 using the Common Runtime (CRT) transfer
#      client (parallel multipart / byte-range -> saturates the NIC, same
#      engine s5cmd uses). CLI v2 uses the standard credential chain, so EKS
#      Pod Identity works natively (no credential shim needed), and it is an
#      official AWS artifact (cleaner supply-chain than third-party s5cmd).
#
# Auth uses EKS Pod Identity (not the node role / IMDS) so it does not depend
# on the IMDS hop limit. The pod-identity-agent addon is already enabled.
################################################################################

# IAM policy: read/write the model cache bucket
resource "aws_iam_policy" "model_uploader_s3" {
  name        = "${local.name}-model-uploader-s3"
  description = "Allows the model-download-s3 job to read/write the model cache bucket."

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

resource "kubectl_manifest" "job_model_download_s3" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: model-download-s3
    spec:
      backoffLimit: 1
      completionMode: NonIndexed
      completions: 1
      template:
        spec:
          serviceAccountName: model-uploader
          nodeSelector:
            instanceType: mixed-x86
            provisionerType: Karpenter
          restartPolicy: Never
          containers:
            - name: pull
              image: python:3.11-slim
              env:
                - name: AWS_REGION
                  value: ${local.region}
                - name: AWS_DEFAULT_REGION
                  value: ${local.region}
                - name: S3_PREFIX
                  value: s3://${local.s3_bucket_name}/mistral-7b-v0.3
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  _t0=$(date +%s); _tp=$_t0
                  step() { local now; now=$(date +%s); echo "[$(date -u +%H:%M:%S)] step took $((now-_tp))s | total $((now-_t0))s | done: $*"; _tp=$now; }

                  echo "[$(date -u +%H:%M:%S)] START - Install dependencies"
                  apt-get update -qq && apt-get install -y -qq --no-install-recommends curl unzip ca-certificates
                  pip install --no-cache-dir "huggingface_hub[hf_xet]"
                  curl --retry 5 --retry-all-errors --retry-delay 3 -fSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
                  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/awscliv2.zip /tmp/aws
                  aws configure set s3.preferred_transfer_client crt
                  step "Dependencies installed + AWS CLI CRT enable"

                  python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id="aws-neuron/Mistral-7B-Instruct-v0.3-seqlen-2048-bs-1-cores-2", local_dir="/tmp/models/mistral-7b-v0.3", max_workers=16)'
                  step "HF download -> /tmp/models ($(du -sh /tmp/models/mistral-7b-v0.3 | cut -f1))"

                  aws s3 cp /tmp/models/mistral-7b-v0.3/ "$S3_PREFIX/" --recursive --exclude ".cache/*"
                  step "aws s3 cp (CRT) -> $S3_PREFIX"
                  
                  echo "[$(date -u +%H:%M:%S)] DONE. Total $(( $(date +%s) - _t0 ))s. Model cached at $S3_PREFIX"
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir: {}
  YAML
  depends_on = [
    kubectl_manifest.mixed-x86_nodepool,
    module.karpenter,
    module.model_uploader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    aws_s3_bucket.model_storage
  ]
}
