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
    vllm/ manifests select pools by name: neuron-trn2-3xl (trn2.3xlarge),
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
  description = "Models to stage, keyed by model name -> HuggingFace checkpoint. The name is the model's folder everywhere: s3://<bucket>/<name>/ (weights + cache/), /tmp/models/<name>/ on nodes (MODEL_ID), and the API model id /tmp/models/<name>. Each gets a model-weights-<name> Job."
  type        = map(string)
  default = {
    "gpt-oss-20b" = "openai/gpt-oss-20b"
  }
}

variable "vllm_gpu_image" {
  description = "vLLM CUDA image for GPU serving (`hardware = \"gpu\"` profiles and the manual vllm/ GPU deployment). Keep the vLLM version in step with vllm_neuron_base_image (vLLM 0.24.0) so GPU and Neuron results compare like for like."
  type        = string
  default     = "vllm/vllm-openai:v0.24.0"
}

variable "serving_profiles" {
  description = <<-EOT
    Validated serving configs ("profiles") the platform publishes for users. Each
    becomes a vllm-profile-<name> ConfigMap (serve flags, S3 paths, image) users can
    read and copy; each `hardware = "neuron"` profile also gets a compile Job that
    precompiles its NEFFs into the model's shared s3://<bucket>/<model>/cache/, so
    any deployment using that exact config + image starts without compiling.
    Empty by default. Profiles are immutable: change a config under a new name
    (e.g. trn2-tp4-16k-v2), or set serving_profiles_allow_mutation. Names:
    lowercase letters, digits and '-', max 40 chars.
  EOT
  type = map(object({
    model                  = string           # key of var.models
    hardware               = string           # neuron | gpu
    nodepool               = string           # NodePool for compile + serving (a capacity_blocks key or an on-demand pool)
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
  default = {}

  validation {
    condition     = alltrue([for k, p in var.serving_profiles : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", k)) && length(k) <= 40])
    error_message = "Profile names must be lowercase letters, digits and '-', max 40 chars."
  }
  validation {
    condition     = alltrue([for p in var.serving_profiles : contains(["neuron", "gpu"], p.hardware)])
    error_message = "Profile hardware must be \"neuron\" or \"gpu\"."
  }
  validation {
    condition     = alltrue([for p in var.serving_profiles : contains(keys(var.models), p.model)])
    error_message = "Every profile's model must be a key of var.models."
  }
}

variable "serving_profiles_allow_mutation" {
  description = "Allow changing an existing serving profile's config in place (running deployments were compiled for the old config - prefer a new profile name)."
  type        = bool
  default     = false
}

