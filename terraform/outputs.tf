################################################################################
# Outputs
################################################################################

output "model_storage_bucket" {
  description = "Name of the S3 bucket holding the model cache."
  value       = aws_s3_bucket.model_storage.bucket
}

output "model_storage_bucket_arn" {
  description = "ARN of the S3 model cache bucket."
  value       = aws_s3_bucket.model_storage.arn
}

# Output the ECR repository URL (versioned tag, encodes vLLM + Ray versions)
output "ray_vllm_image_uri" {
  value = "${aws_ecr_repository.ray_vllm.repository_url}:${local.ray_vllm_image_tag}"
}
output "configure_kubectl" {
  description = "Command to update the local kubeconfig for the EKS cluster."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

output "vllm_neuron_image" {
  description = "vLLM-Neuron image shared by every Neuron workload (compile Jobs, vLLM serving)."
  value       = var.vllm_neuron_base_image
}

output "serving_profiles" {
  description = "Validated serving profiles published to the cluster (vllm-profile-<name> ConfigMaps)."
  value       = keys(var.serving_profiles)
}

output "vllm_gpu_image" {
  description = "vLLM CUDA image for GPU serving (manual vllm/ GPU deployment, gpu profiles)."
  value       = var.vllm_gpu_image
}

output "region" {
  description = "AWS region the cluster runs in."
  value       = local.region
}
