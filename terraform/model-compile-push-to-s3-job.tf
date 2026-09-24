################################################################################
# Model compile -> S3
#
# One-shot Job that prepares the Neuron model cache for gpt-oss-20b. It runs on
# the neuron-trn2 Karpenter pool and compiles by launching the EXACT `vllm serve`
# command used at serve time - the standalone vLLM Neuron plugin (0.24) compiles
# the model graphs on first launch before accepting traffic and keys the cached
# NEFFs by config, so running the identical command guarantees the serving pods
# reuse the cache instead of recompiling (gpt-oss cold compile is 20-40 min).
# Three phases:
#   1. Download the upstream openai/gpt-oss-20b from HuggingFace via
#      huggingface_hub (hf_xet backend for fast transfer).
#   2. Launch `vllm serve` with the serve config; wait for /health to go ready
#      (= compilation complete). The plugin writes NEFFs under VLLM_CACHE_ROOT,
#      which lives inside the model dir.
#   3. Upload the model dir (weights + VLLM_CACHE_ROOT) to S3. Serving pulls that
#      dir and points VLLM_CACHE_ROOT at it, so model load skips compilation.
#      Serve config is shared via env vars / identical flags to guarantee reuse.
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
      # gpt-oss cold compile is 20-40 min (plus the ~40 GB HF download); allow
      # generous headroom before the Job is killed for exceeding its deadline.
      activeDeadlineSeconds: 7200
      template:
        spec:
          serviceAccountName: model-uploader
          restartPolicy: Never

          # Compile runs on trn2 by launching the exact serve command, so the
          # NEFFs the plugin writes to VLLM_CACHE_ROOT match the config the
          # serving pods look up (a mismatch would force a recompile).
          nodeSelector:
            karpenter.sh/nodepool: neuron-trn2
          tolerations:
            - key: aws.amazon.com/neuron
              operator: Exists
              effect: NoSchedule
            - key: karpenter
              operator: Exists
              effect: NoSchedule

          initContainers:
            # 1. Download the upstream model from HuggingFace. HF_REPO_ID and
            # MODEL_DIR are read from env (via os.environ, since a shell $VAR
            # wouldn't expand inside the python -c literal), so the download path
            # stays in sync with MODEL_ID in the compile container below.
            - name: download-upstream
              image: python:3.11-slim
              command: ["/bin/bash", "-c"]
              env:
                - name: HF_REPO_ID
                  value: openai/gpt-oss-20b
                - name: MODEL_DIR
                  value: /tmp/models/gpt-oss-20b
              args:
                - |
                  set -euo pipefail
                  pip install --no-cache-dir "huggingface_hub[hf_xet]"
                  python -c 'import os; from huggingface_hub import snapshot_download; snapshot_download(repo_id=os.environ["HF_REPO_ID"], local_dir=os.environ["MODEL_DIR"], max_workers=16)'
                  echo "Downloaded upstream model: $(du -sh "$MODEL_DIR" | cut -f1)"
              volumeMounts:
                - name: work
                  mountPath: /tmp/models

          # 2. Compile + upload in ONE main container that owns the Neuron device.
          containers:
            - name: compile-and-upload
              image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.24.0.1.1.0-neuronx-py313-sdk2.32.0-ubuntu24.04
              env:
                # NEFF cache lives inside the model dir so it is uploaded with the
                # weights and reused at serve time (local dir, not s3://).
                - name: VLLM_CACHE_ROOT
                  value: /tmp/models/gpt-oss-20b/cache
                # gpt-oss needs long compile/execute timeouts.
                - name: VLLM_NEURON_COMPILATION_TIMEOUT
                  value: "1200"
                - name: VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS
                  value: "1200"
                # Serve config - MUST match the serving manifests (same env names,
                # including the HF_OVERRIDES / ADDITIONAL_CONFIG JSON below). A
                # mismatch changes the NEFF cache key and forces a recompile.
                - name: MODEL_ID
                  value: /tmp/models/gpt-oss-20b
                - name: TENSOR_PARALLEL_SIZE
                  value: "8"
                - name: MAX_NUM_SEQS
                  value: "4"
                - name: MAX_NUM_BATCHED_TOKENS
                  value: "8192"
                - name: MAX_MODEL_LEN
                  value: "16384"
                - name: HF_OVERRIDES
                  value: '{"quantization_config": {}}'
                - name: ADDITIONAL_CONFIG
                  value: '{"neuron_config":{"num_batched_tokens_buckets":[8192],"num_seqs_buckets":[4]}}'
                - name: NEURON_RT_NUM_CORES
                  value: "8"
                # trn2 nodes here have no EFA; EFA affinity is a CPU perf hint,
                # not required for single-instance TP8 (collectives use NeuronLink).
                - name: NEURON_SKIP_EFA_AFFINITY
                  value: "1"
                - name: AWS_REGION
                  value: ${local.region}
                - name: S3_PREFIX
                  value: s3://${local.s3_bucket_name}/gpt-oss-20b
              resources:
                # Dedicate the whole trn2.48xlarge (16 Neuron devices / 64 logical
                # NeuronCores). TP8 uses 8 cores; the node hosts only this workload.
                requests:
                  cpu: 32
                  memory: 128Gi
                  aws.amazon.com/neuron: "16"
                limits:
                  cpu: 48
                  memory: 128Gi
                  aws.amazon.com/neuron: "16"
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail

                  # Compile by launching the EXACT serve command; the plugin
                  # compiles the graphs before /health goes ready, writing NEFFs
                  # to VLLM_CACHE_ROOT. Keep these flags in sync with the serving
                  # manifests (vllm/ + ray/) or the cache won't be reused.
                  vllm serve "$MODEL_ID" \
                    --tokenizer "$MODEL_ID" \
                    --host 0.0.0.0 --port 8000 \
                    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE" \
                    --max-model-len "$MAX_MODEL_LEN" \
                    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
                    --max-num-seqs "$MAX_NUM_SEQS" \
                    --enable-prefix-caching \
                    --no-disable-hybrid-kv-cache-manager \
                    --hf-overrides "$HF_OVERRIDES" \
                    --additional-config "$ADDITIONAL_CONFIG" &
                  VLLM_PID=$!

                  # Wait up to 2 hr for compile to finish (health = ready).
                  ready=0
                  for i in $(seq 1 720); do
                    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
                      echo "vllm serve exited during compile" >&2; break
                    fi
                    if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
                      echo "Compile complete, server ready after $((i*10))s"; ready=1; break
                    fi
                    sleep 10
                  done
                  kill "$VLLM_PID" 2>/dev/null || true
                  wait "$VLLM_PID" 2>/dev/null || true
                  if [ "$ready" -ne 1 ]; then echo "Server never became ready" >&2; exit 1; fi

                  # Upload weights + NEFF cache to S3 (AWS CLI v2 + CRT).
                  apt-get update -qq && apt-get install -y -qq --no-install-recommends curl unzip ca-certificates
                  curl --retry 5 --retry-all-errors --retry-delay 3 -fSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
                  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update && rm -rf /tmp/awscliv2.zip /tmp/aws
                  aws configure set s3.preferred_transfer_client crt
                  aws s3 sync "$MODEL_ID/" "$S3_PREFIX/"
                  echo "Uploaded weights + NEFF cache to $S3_PREFIX"
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
    kubectl_manifest.karpenter["neuron-trn2-nodepool.yaml"],
    module.karpenter,
    module.model_uploader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    aws_s3_bucket.model_storage
  ]
}
