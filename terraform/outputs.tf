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

output "serving_images" {
  description = "Image URI:tag per folder of container-images/, for the Helm releases' image value, e.g. terraform output -json serving_images | jq -r '.\"vllm-neuron\"'."
  value       = local.image_uris
}
