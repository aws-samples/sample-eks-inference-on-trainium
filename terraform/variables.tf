variable "region" {
  description = "AWS region to deploy the workshop into."
  type        = string
  default     = "us-east-2"

  validation {
    condition     = contains(["us-west-2", "us-east-2", "eu-west-1"], var.region)
    error_message = "Supported regions are us-west-2, us-east-2, and eu-west-1."
  }
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
