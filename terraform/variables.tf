variable "region" {
  description = "AWS region to deploy the workshop into."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Name for the EKS cluster."
  type        = string
  default     = "demo-neuron-eks"
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "x86_ami_name" {
  description = "EKS-optimized AL2023 x86_64 (standard) AMI name for the x86 Karpenter NodeClass."
  type        = string
  default     = "amazon-eks-node-al2023-x86_64-standard-1.36-v20260903"
}

variable "neuron_ami_name" {
  description = "EKS-optimized AL2023 x86_64 Neuron AMI name for the shared Neuron Karpenter NodeClass (trn1, trn2, inf2)."
  type        = string
  default     = "amazon-eks-node-al2023-x86_64-neuron-1.36-v20260903"
}

variable "gpu_ami_name" {
  description = "EKS-optimized AL2023 x86_64 NVIDIA AMI name for the shared GPU Karpenter NodeClass (g6, g6e, g7, g7e)."
  type        = string
  default     = "amazon-eks-node-al2023-x86_64-nvidia-1.36-v20260903"
}

variable "capacity_blocks" {
  description = <<-EOT
    ML Capacity Blocks / EC2 Capacity Reservations to run, keyed by NodePool name.
    Each becomes a static Karpenter NodePool that keeps all `node_count` instances
    of the block running (reserved capacity only, pinned to the block's instance
    type and AZ), and its reservation is added to the hardware's NodeClass. The
    vllm/ manifests select pools by name: neuron-trn2 (trn2.3xlarge),
    neuron-trn2-48xl (trn2.48xlarge), gpu-p5-48xl (p5.48xlarge).
  EOT
  type = map(object({
    reservation_id = string                    # cr-... (aws ec2 describe-capacity-reservations)
    az             = string                    # the reservation's AZ (must match)
    instance_type  = string                    # e.g. trn2.3xlarge, trn2.48xlarge, p5.48xlarge
    node_count     = number                    # instances in the block (static replicas)
    hardware       = string                    # neuron | gpu
    expire_after   = optional(string, "Never") # node lifetime; Never = until the block ends
  }))
  default = {}

  validation {
    condition     = alltrue([for k, b in var.capacity_blocks : contains(["neuron", "gpu"], b.hardware)])
    error_message = "capacity_blocks[*].hardware must be \"neuron\" or \"gpu\"."
  }
  validation {
    condition     = alltrue([for k, b in var.capacity_blocks : b.node_count >= 1 && floor(b.node_count) == b.node_count])
    error_message = "capacity_blocks[*].node_count must be a whole number >= 1."
  }
}

variable "vllm_neuron_base_image" {
  description = "vLLM-Neuron DLC image used by every Neuron workload: the compile Jobs and vLLM serving run it directly, and the Ray serving image is built FROM it (tag derived from this + ray_version). Its tag is part of the S3 NEFF cache path, since NEFFs only match the SDK/compiler they were built with."
  type        = string
  default     = "public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.24.0.1.1.0-neuronx-py313-sdk2.32.0-ubuntu24.04"
}

variable "ray_version" {
  description = "Ray version installed on top of the base image. Must have py3.13 wheels and be compatible with the KubeRay operator (1.7.x -> Ray 2.55/2.56). Keep in sync with rayVersion in ray/ray-service-trn2.yaml."
  type        = string
  default     = "2.56.1"
}

variable "models" {
  description = "Models to stage in S3: model dir name -> HuggingFace repo. Each gets a model-weights-<name> Job that uploads it to s3://<bucket>/<name>/ (mirrored on nodes at /tmp/models/<name>/)."
  type        = map(string)
  default = {
    "gpt-oss-20b" = "openai/gpt-oss-20b"
  }
}

variable "model_name" {
  description = "Model (a key of var.models) the serving platform builds profiles for."
  type        = string
  default     = "gpt-oss-20b"

  validation {
    condition     = contains(keys(var.models), var.model_name)
    error_message = "model_name must be a key of var.models."
  }
}

variable "vllm_gpu_image" {
  description = "vLLM CUDA image for GPU serving (`hardware = \"gpu\"` profiles and the manual vllm/ GPU deployment). Keep the vLLM version in step with vllm_neuron_base_image (vLLM 0.24.0) so GPU and Neuron results compare like for like."
  type        = string
  default     = "vllm/vllm-openai:v0.24.0"
}

variable "serving_profiles" {
  description = <<-EOT
    Serving profiles the cluster supports - the catalog users deploy from with the
    platform-charts/serving chart. Each becomes a vllm-profile-<name> ConfigMap; each
    `hardware = "neuron"` profile also gets a compile Job that precompiles its NEFFs
    to S3. Profiles are immutable: change the config under a new name (e.g.
    trn2-tp8-16k-v2), or set serving_profiles_allow_mutation. Names: lowercase
    letters, digits and '-', max 40 chars.
  EOT
  type = map(object({
    hardware               = string           # neuron | gpu
    nodepool               = string           # Karpenter NodePool for compile + serving
    devices                = number           # accelerator devices per pod
    cpu                    = optional(string) # serving + compile pod requests/limits
    memory                 = optional(string)
    tensor_parallel_size   = number
    max_model_len          = number
    max_num_seqs           = number
    max_num_batched_tokens = number
    hf_overrides           = optional(string, "") # --hf-overrides JSON
    additional_config      = optional(string, "") # --additional-config JSON
    env                    = optional(map(string), {})
  }))
  default = {
    # Single trn2.3xlarge (1 Trainium2 device = 4 logical NeuronCores at the
    # plugin's default LNC=2, 12 vCPU, 128 GiB) -> TP4 max. cpu/memory leave
    # headroom below the node's allocatable for system daemonsets.
    "trn2-tp4-16k" = {
      hardware               = "neuron"
      nodepool               = "neuron-trn2"
      devices                = 1
      cpu                    = "10"
      memory                 = "112Gi"
      tensor_parallel_size   = 4
      max_model_len          = 16384
      max_num_seqs           = 4
      max_num_batched_tokens = 8192
      hf_overrides           = "{\"quantization_config\": {}}"
      additional_config      = "{\"neuron_config\":{\"num_batched_tokens_buckets\":[8192],\"num_seqs_buckets\":[4]}}"
    }
  }

  validation {
    condition     = alltrue([for k, p in var.serving_profiles : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", k)) && length(k) <= 40])
    error_message = "Profile names must be lowercase letters, digits and '-', max 40 chars."
  }
  validation {
    condition     = alltrue([for p in var.serving_profiles : contains(["neuron", "gpu"], p.hardware)])
    error_message = "Profile hardware must be \"neuron\" or \"gpu\"."
  }
}

variable "serving_profiles_allow_mutation" {
  description = "Allow changing an existing serving profile's config in place (running deployments were compiled for the old config - prefer a new profile name)."
  type        = bool
  default     = false
}

variable "enable_serving_platform" {
  description = "Install the serving platform (platform-charts/serving-platform): profile catalog + NEFF compile Jobs, for users deploying with platform-charts/serving. false = infra + weights in S3 only, for the manual vllm/ and ray/ manifests."
  type        = bool
  default     = false
}
