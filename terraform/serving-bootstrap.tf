################################################################################
# Serving bootstrap - everything that prepares the cluster to serve models,
# after the infra (EKS, Karpenter, S3) is up:
#   1. Model storage access: S3 IAM + Pod Identity for the model-uploader
#      (read/write) and model-reader (read-only) ServiceAccounts.
#   2. Model weights: one model-weights-<model> Job per var.models entry.
#   3. Ray image warmer: pre-pulls the Ray serving image on Karpenter nodes.
#   4. Validated serving profiles: the validate-serving-profiles Helm release
#      (profile ConfigMaps, vended serve scripts, NEFF compile Jobs).
# Kubernetes objects are plain YAML under ./manifests (rendered with file() /
# templatefile()); the profiles chart is ./validate-serving-profiles.
################################################################################

################################################################################
# 1. Model storage access
#
# model-uploader (S3 read/write): the weights and compile Jobs. model-reader
# (S3 read-only): every serving pod's init container pulls the model dir to NVMe.
# Both via EKS Pod Identity, not the node role / IMDS.
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
# the <model>/.ready/weights marker. Markers live under <model>/.ready/ (also
# .ready/cache/<image-tag>/<profile> for the profile compile Jobs).
#
# Layout (same everywhere - S3 mirrors the node-local NVMe dir):
#   s3://<bucket>/<model>/        <->  /tmp/models/<model>/        MODEL_ID (weights)
#   s3://<bucket>/<model>/cache/  <->  /tmp/models/<model>/cache/  VLLM_CACHE_ROOT
#   s3://<bucket>/benchmarks/                                      benchmark results
#
# The validated serving profiles (section 4) get the same S3 paths from these
# locals; their compile Jobs reuse the model-uploader SA.
################################################################################

# S3 paths per model (var.models); shared by the weights Jobs and the serving
# platform's profiles.
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
# 3. Ray/vLLM image warmer
#
# A DaemonSet that pre-pulls the large custom Ray + vLLM image onto every
# Karpenter node, so real Ray head/worker pods skip the multi-GB pull and start
# faster. The container does nothing but sleep - the value is purely the image
# pull that kubelet does to run it (cached for later pods via IfNotPresent).
#
# Placement:
#   - nodeSelector provisionerType=Karpenter -> all Karpenter pools, never the
#     managed node group (the MNG nodes don't carry that label).
#   - tolerations: Exists (all taints) -> lands on the neuron/gpu/karpenter
#     tainted pools too.
#   - requests no accelerator, so it never consumes a Neuron/GPU device.
################################################################################

resource "kubectl_manifest" "ray_image_warmer" {
  server_side_apply = true
  # Don't block the apply on the DaemonSet rollout: it only reaches every
  # matching node eventually (nodes come and go with Karpenter), and a stale
  # rollout wait has hung applies indefinitely.
  wait_for_rollout = false
  yaml_body = templatefile("${path.module}/manifests/ray-image-warmer-daemonset.yaml", {
    image = "${aws_ecr_repository.ray_vllm.repository_url}:${local.ray_vllm_image_tag}"
  })
  depends_on = [module.eks, aws_ecr_repository.ray_vllm]
}

################################################################################
# 4. Validated serving profiles + NEFF compile Jobs
# (Helm chart: ./validate-serving-profiles)
#
# Admins define var.models (model name -> HF checkpoint) and var.serving_profiles
# (validated serve configs, each tied to a model and a NodePool). Terraform
# renders them, plus the infra values (region, S3 paths, images), into the chart,
# which publishes:
#   - vllm-profile-<name> ConfigMaps: the profile's serve flags, S3 paths and
#     image, for users to read and copy (kubectl get cm -l serving.platform/profile)
#   - vllm-serve-script: the vended launch scripts (vllm serve + Ray app)
#   - one compile Job per Neuron profile, which waits for the model's
#     model-weights-<model> marker, compiles, and adds its NEFFs to the model's
#     shared s3://<bucket>/<model>/cache/ - so any deployment that uses the same
#     config + image (profile-based or hand-written) starts without compiling.
# With no profiles (the default) only the serve scripts are published. Users
# deploy however they like; staying on a profile is what keeps them precompiled.
################################################################################

locals {
  validate_serving_profiles_chart = "${path.module}/validate-serving-profiles"

  # NodePools a profile can target: the Capacity Block pools plus the on-demand
  # pools under karpenter/nodepools (name -> hardware + allowed instance types).
  karpenter_ondemand_pools = {
    for f in fileset("${path.module}/karpenter", "nodepools/*.yaml") :
    yamldecode(templatefile("${path.module}/karpenter/${f}", local.karpenter_template_vars)).metadata.name =>
    yamldecode(templatefile("${path.module}/karpenter/${f}", local.karpenter_template_vars)).spec.template.spec
  }
  serving_pools = merge(
    {
      for name, spec in local.karpenter_ondemand_pools : name => {
        hardware       = spec.nodeClassRef.name
        instance_types = flatten([for r in spec.requirements : r.values if r.key == "node.kubernetes.io/instance-type"])
      }
    },
    {
      for name, b in var.capacity_blocks : name => {
        hardware       = b.hardware
        instance_types = [b.instance_type]
      }
    },
  )

  # Accelerators per instance type (Neuron: logical NeuronCores per device at the
  # default LNC). Instance types not listed here skip the size checks.
  accelerator_capacity = {
    "trn2.3xlarge"  = { devices = 1, cores_per_device = 4 }
    "trn2.48xlarge" = { devices = 16, cores_per_device = 4 }
    "trn1.2xlarge"  = { devices = 1, cores_per_device = 2 }
    "trn1.32xlarge" = { devices = 16, cores_per_device = 2 }
    "inf2.8xlarge"  = { devices = 1, cores_per_device = 2 }
    "inf2.48xlarge" = { devices = 12, cores_per_device = 2 }
    "p5.4xlarge"    = { devices = 1, cores_per_device = 1 }
    "p5.48xlarge"   = { devices = 8, cores_per_device = 1 }
    "g6.8xlarge"    = { devices = 1, cores_per_device = 1 }
    "g6e.8xlarge"   = { devices = 1, cores_per_device = 1 }
  }

  # Plan-time checks so a profile can't silently sit Pending forever.
  serving_profile_problems = flatten([
    for name, p in var.serving_profiles : (
      !contains(keys(local.serving_pools), p.nodepool)
      ? ["profile ${name}: nodepool \"${p.nodepool}\" doesn't exist (use a capacity_blocks key or one of: ${join(", ", sort(keys(local.karpenter_ondemand_pools)))})"]
      : concat(
        local.serving_pools[p.nodepool].hardware == p.hardware ? [] : [
          "profile ${name}: hardware \"${p.hardware}\" doesn't match nodepool ${p.nodepool} (${local.serving_pools[p.nodepool].hardware})"
        ],
        flatten([
          for it in local.serving_pools[p.nodepool].instance_types : lookup(local.accelerator_capacity, it, null) == null ? [] : concat(
            p.devices <= local.accelerator_capacity[it].devices ? [] : [
              "profile ${name}: devices ${p.devices} > ${local.accelerator_capacity[it].devices} on ${it}"
            ],
            p.tensor_parallel_size <= p.devices * local.accelerator_capacity[it].cores_per_device ? [] : [
              "profile ${name}: tensor_parallel_size ${p.tensor_parallel_size} > ${p.devices * local.accelerator_capacity[it].cores_per_device} (${p.devices} device(s) x ${local.accelerator_capacity[it].cores_per_device} on ${it})"
            ],
          )
        ]),
      )
    )
  ])

  validate_serving_profiles_values = {
    region = local.region
    models = {
      for name, repo in var.models : name => {
        hfRepoId        = repo
        s3Uri           = local.model_s3[name].uri
        weightsReadyUri = local.model_s3[name].weightsReadyUri
      }
    }
    images = {
      neuron    = var.vllm_neuron_base_image
      neuronRay = "${aws_ecr_repository.ray_vllm.repository_url}:${local.ray_vllm_image_tag}"
      gpu       = var.vllm_gpu_image
    }
    ray = {
      version = var.ray_version
    }
    allowProfileMutation = var.serving_profiles_allow_mutation
    # Map tfvars (snake_case) onto the chart's profile schema.
    profiles = {
      for name, p in var.serving_profiles : name => {
        model               = p.model
        hardware            = p.hardware
        nodepool            = p.nodepool
        devices             = p.devices
        resources           = { for k, v in { cpu = p.cpu, memory = p.memory } : k => v if v != null }
        tensorParallelSize  = p.tensor_parallel_size
        maxModelLen         = p.max_model_len
        maxNumSeqs          = p.max_num_seqs
        maxNumBatchedTokens = p.max_num_batched_tokens
        hfOverrides         = p.hf_overrides
        additionalConfig    = p.additional_config
        env                 = p.env
      }
    }
  }
}

resource "helm_release" "validate_serving_profiles" {
  name      = "validate-serving-profiles"
  namespace = "default"
  chart     = local.validate_serving_profiles_chart
  # Compile Jobs run for 20-40 min; don't block the apply on them.
  wait = false

  values = [yamlencode(local.validate_serving_profiles_values)]

  # A local chart's template edits don't change its version, so pass a content
  # hash to make Terraform roll the release when the chart itself changes.
  set {
    name  = "chartChecksum"
    value = sha1(join("", [for f in sort(fileset(local.validate_serving_profiles_chart, "**")) : filesha1("${local.validate_serving_profiles_chart}/${f}")]))
  }

  lifecycle {
    precondition {
      condition     = length(local.serving_profile_problems) == 0
      error_message = "Invalid serving_profiles:\n${join("\n", local.serving_profile_problems)}"
    }
  }

  depends_on = [
    kubectl_manifest.karpenter,
    kubectl_manifest.karpenter_capacity_block,
    module.model_uploader_pod_identity,
    module.model_reader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    kubectl_manifest.model_reader_sa,
  ]
}
