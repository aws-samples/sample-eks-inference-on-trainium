################################################################################
# Serving platform: profile catalog + NEFF compile Jobs (platform-charts/serving-platform)
#
# var.serving_profiles is the platform team's single interface: Terraform renders
# it, plus the infra values (region, S3 paths, images), into the chart. The chart
# publishes one vllm-profile-<name> ConfigMap per profile, the vended launch
# scripts, and one compile Job per Neuron profile (which waits for the
# model-weights-<model> marker, so no ordering dependency on that Job is needed).
# Users then deploy endpoints from the catalog with platform-charts/serving.
#
# var.enable_serving_platform = false skips it: infra + weights in S3 only, for
# the manual vllm/ and ray/ manifests (which compile on first start, on-node).
################################################################################

locals {
  serving_platform_chart = "${path.module}/../platform-charts/serving-platform"

  serving_platform_values = {
    region = local.region
    model = {
      name = var.model_name
    }
    s3 = {
      modelUri        = local.s3_model_uri
      weightsReadyUri = local.s3_weights_ready_uri
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

resource "helm_release" "serving_platform" {
  count = var.enable_serving_platform ? 1 : 0

  name      = "serving-platform"
  namespace = "default"
  chart     = local.serving_platform_chart
  # Compile Jobs run for 20-40 min; don't block the apply on them.
  wait = false

  values = [yamlencode(local.serving_platform_values)]

  # A local chart's template edits don't change its version, so pass a content
  # hash to make Terraform roll the release when the chart itself changes.
  set {
    name  = "chartChecksum"
    value = sha1(join("", [for f in sort(fileset(local.serving_platform_chart, "**")) : filesha1("${local.serving_platform_chart}/${f}")]))
  }

  depends_on = [
    kubectl_manifest.karpenter,
    module.model_uploader_pod_identity,
    module.model_reader_pod_identity,
    kubectl_manifest.model_uploader_sa,
    kubectl_manifest.model_reader_sa,
  ]
}
