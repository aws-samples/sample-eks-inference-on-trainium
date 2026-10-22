variable "region" {
  description = "AWS region to deploy into. Must be where your Capacity Blocks are."
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
  description = "EKS-optimized AL2023 x86_64 Neuron AMI name for the shared neuron Karpenter NodeClass (trn2)."
  type        = string
  default     = "amazon-eks-node-al2023-x86_64-neuron-1.36-v20260903"
}

variable "gpu_ami_name" {
  description = "EKS-optimized AL2023 x86_64 NVIDIA AMI name for the shared gpu Karpenter NodeClass (p5, g6e)."
  type        = string
  default     = "amazon-eks-node-al2023-x86_64-nvidia-1.36-v20260903"
}

variable "capacity_blocks_nodepools" {
  description = <<-EOT
    Static Karpenter NodePools to create, one per ML Capacity Block: the key is
    the NodePool name, the value the block's details. Each NodePool keeps all
    node_count instances of the block running (reserved capacity, pinned to the
    block's instance type and AZ), and the reservation is added to the
    hardware's NodeClass (neuron | gpu).
  EOT
  type = map(object({
    reservation_id = string # cr-... (aws ec2 describe-capacity-reservations)
    instance_type  = string # e.g. trn2.48xlarge, p5.48xlarge
    az             = string # the reservation's AZ
    node_count     = number # instances in the block
    hardware       = string # neuron | gpu
  }))
  default = {}

  validation {
    condition     = alltrue([for k, b in var.capacity_blocks_nodepools : contains(["neuron", "gpu"], b.hardware)])
    error_message = "capacity_blocks_nodepools[*].hardware must be \"neuron\" or \"gpu\"."
  }
  validation {
    condition     = alltrue([for k, b in var.capacity_blocks_nodepools : can(regex("^cr-[0-9a-f]+$", b.reservation_id))])
    error_message = "capacity_blocks_nodepools[*].reservation_id must be a Capacity Reservation ID (cr-...)."
  }
}

variable "existing_cache_bucket" {
  description = "Name of an existing S3 bucket to use for the model weights and benchmark results, e.g. one from an earlier cluster. Empty: create a new bucket. An existing bucket is never modified or deleted by Terraform; keep it in var.region (the S3 gateway endpoint only covers same-region buckets) and in this account."
  type        = string
  default     = ""
}

variable "models" {
  description = "Models to stage, keyed by model name -> HuggingFace checkpoint. The name is the model's folder everywhere: s3://<bucket>/<name>/ (weights + cache/), /tmp/models/<name>/ on nodes (MODEL_ID and the API model id). Each gets a model-weights-<name> Job."
  type        = map(string)
  default = {
    "gpt-oss-20b" = "openai/gpt-oss-20b"
  }
}
