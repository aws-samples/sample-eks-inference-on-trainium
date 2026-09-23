################################################################################
# Model compile -> S3
#
# One-shot Job that prepares the Neuron model cache. It runs on the neuron-trn1
# Karpenter pool because it compiles through vLLM's own offline path, which
# guarantees the NEFF matches the exact vLLM version + config used at serve time.
# Three phases:
#   1. Download the UPSTREAM (uncompiled) mistralai/Mistral-7B-Instruct-v0.3
#      from HuggingFace via huggingface_hub (hf_xet backend for fast transfer).
#   2. Run one offline vLLM inference with the serve config; NxDI writes the
#      full compiled model tree (NEFFs, sharded weights, metadata) into
#      NEURON_COMPILED_ARTIFACTS, colocated with the model dir.
#   3. Upload the model dir (weights + compiled artifacts) to S3. Serving pulls
#      that dir and points NEURON_COMPILED_ARTIFACTS at it, so model load skips
#      compilation entirely. Serve config is shared via env vars to guarantee
#      the compiled artifacts are reused (a mismatch would force a recompile).
#
# Auth uses EKS Pod Identity (model-uploader SA), not the node role / IMDS.
################################################################################

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

resource "kubectl_manifest" "job_model_compile_s3" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: model-compile-s3
    spec:
      backoffLimit: 1
      completionMode: NonIndexed
      completions: 1
      template:
        spec:
          serviceAccountName: model-uploader
          restartPolicy: Never

          # Compile runs on trn1 because it uses vLLM's own offline path (which
          # initializes the Neuron runtime) - this guarantees the compiled
          # artifacts match the exact vLLM version + config used at serve time.
          # NxDI writes the full compiled model tree into NEURON_COMPILED_ARTIFACTS,
          # which is then uploaded to S3 for serving to pull.
          nodeSelector:
            karpenter.sh/nodepool: neuron-trn1
          tolerations:
            - key: aws.amazon.com/neuron
              operator: Exists
              effect: NoSchedule
            - key: karpenter
              operator: Exists
              effect: NoSchedule

          initContainers:
            # 1. Download the UPSTREAM (uncompiled) model from HuggingFace.
            - name: download-upstream
              image: python:3.11-slim
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  pip install --no-cache-dir "huggingface_hub[hf_xet]"
                  python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id="mistralai/Mistral-7B-Instruct-v0.3", local_dir="/tmp/models/mistral-7b-v0.3", max_workers=16, ignore_patterns=["consolidated.safetensors"])'
                  echo "Downloaded upstream model: $(du -sh /tmp/models/mistral-7b-v0.3 | cut -f1)"
              volumeMounts:
                - name: work
                  mountPath: /tmp/models

          # 2. Compile + upload in ONE main container that owns the Neuron device.
          containers:
            - name: compile-and-upload
              image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.16.0-neuronx-py312-sdk2.31.1-ubuntu24.04
              env:
                - name: VLLM_NEURON_FRAMEWORK
                  value: neuronx-distributed-inference
                - name: NEURON_COMPILED_ARTIFACTS
                  value: /tmp/models/mistral-7b-v0.3
                # neuronx-cc kernel cache in the model dir so it is uploaded with
                # the model and reused at serve time (local dir, not s3://).
                - name: NEURON_COMPILE_CACHE_URL
                  value: /tmp/models/mistral-7b-v0.3
                # Serve config - MUST match the serving manifests (same env names).
                - name: MODEL_ID
                  value: /tmp/models/mistral-7b-v0.3
                - name: TENSOR_PARALLEL_SIZE
                  value: "2"
                - name: MAX_NUM_SEQS
                  value: "4"
                - name: MAX_MODEL_LEN
                  value: "2048"
                - name: DTYPE
                  value: bfloat16
                - name: NEURON_RT_NUM_CORES
                  value: "2"
                - name: NEURON_RT_VISIBLE_CORES
                  value: "0,1"
                - name: AWS_REGION
                  value: ${local.region}
                - name: S3_PREFIX
                  value: s3://${local.s3_bucket_name}/mistral-7b-v0.3
              resources:
                requests:
                  cpu: 4
                  memory: 26Gi
                  aws.amazon.com/neuron: "1"
                limits:
                  cpu: 8
                  memory: 26Gi
                  aws.amazon.com/neuron: "1"
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail

                  # Compile bootstrap script, embedded from scripts/compile_model.py
                  # (base64 avoids YAML/heredoc indentation issues), decoded and run.
                  echo "${base64encode(file("${path.module}/scripts/compile_model.py"))}" | base64 -d > /tmp/compile_model.py
                  python /tmp/compile_model.py

                  # vLLM writes the compiled NEFF tree to /tmp/nxd_model regardless of
                  # NEURON_COMPILED_ARTIFACTS, so copy it into the model dir before upload.
                  cp -a /tmp/nxd_model/. "$NEURON_COMPILED_ARTIFACTS/"

                  # Upload weights + compiled artifacts to S3 (AWS CLI v2 + CRT).
                  apt-get update -qq && apt-get install -y -qq --no-install-recommends curl unzip ca-certificates
                  curl --retry 5 --retry-all-errors --retry-delay 3 -fSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
                  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update && rm -rf /tmp/awscliv2.zip /tmp/aws
                  aws configure set s3.preferred_transfer_client crt
                  aws s3 sync "$NEURON_COMPILED_ARTIFACTS/" "$S3_PREFIX/" --exclude ".cache/*"
                  echo "Uploaded weights + compiled artifacts to $S3_PREFIX"
              volumeMounts:
                - name: work
                  mountPath: /tmp/models
          volumes:
            # NVMe instance store (same path serving uses), so the compile writes
            # to fast local disk and a warm node can be reused by a serving pod.
            - name: work
              hostPath:
                path: /mnt/k8s-disks/0
                type: Directory
  YAML
  depends_on = [
    kubectl_manifest.karpenter["neuron-trn1-nodepool.yaml"],
    module.karpenter,
    module.model_uploader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    aws_s3_bucket.model_storage
  ]
}
