################################################################################
# Outputs - the values the next steps need, e.g.
#   export S3_BUCKET_NAME=$(terraform -chdir=terraform output -raw model_storage_bucket)
################################################################################

output "region" {
  description = "AWS region the cluster runs in."
  value       = local.region
}

output "configure_kubectl" {
  description = "Command to update the local kubeconfig for the EKS cluster."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

output "model_storage_bucket" {
  description = "S3 bucket: model weights (<model>/), Neuron compile cache (<model>/cache/), benchmark results (benchmarks/)."
  value       = local.s3_bucket_name
}

output "vllm_neuron_image" {
  description = "ECR copy of var.vllm_neuron_image (Neuron compile + serving)."
  value       = "${aws_ecr_repository.vllm["neuron"].repository_url}:${local.vllm_image_tags["neuron"]}"
}

output "vllm_gpu_image" {
  description = "ECR copy of var.vllm_gpu_image (GPU serving)."
  value       = "${aws_ecr_repository.vllm["gpu"].repository_url}:${local.vllm_image_tags["gpu"]}"
}

output "ray_neuron_image" {
  description = "Ray Serve image built FROM vllm_neuron_image (optional Ray path)."
  value       = "${aws_ecr_repository.ray["neuron"].repository_url}:${local.ray_image_tags["neuron"]}"
}

output "ray_gpu_image" {
  description = "Ray Serve image built FROM vllm_gpu_image (optional Ray path)."
  value       = "${aws_ecr_repository.ray["gpu"].repository_url}:${local.ray_image_tags["gpu"]}"
}
