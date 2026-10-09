terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.86.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.3"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
  registry {
    url      = "oci://public.ecr.aws"
    username = data.aws_ecrpublic_authorization_token.token.user_name
    password = data.aws_ecrpublic_authorization_token.token.password
  }

}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}


data "aws_caller_identity" "current" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  name   = var.name
  region = var.region

  # Globally-unique bucket name for the model cache (S3 path, alternative to FSx)
  s3_bucket_name = "${local.name}-model-storage-${data.aws_caller_identity.current.account_id}-${var.region}"

  # Serving image = vLLM-Neuron DLC base (var.vllm_neuron_base_image) + Ray
  # (var.ray_version). Those two variables are the single source of truth: they're
  # injected into the CodeBuild buildspec (FROM + pip) and compose the image tag
  # below, so the tag encodes exactly what's inside.
  # e.g. 0.24.0.1.1.0-neuronx-py313-sdk2.32.0-ubuntu24.04-ray2.56.1
  # Immutable per (vLLM, Ray) combo -> no more mutable :latest / stale-pull bug.
  ray_vllm_image_tag = "ray${var.ray_version}-vllm${split(":", var.vllm_neuron_base_image)[1]}"

  tags = {}
}
