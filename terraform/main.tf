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
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
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
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}


data "aws_caller_identity" "current" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  name = var.name
  region = var.region

  # Globally-unique bucket name for the model cache (S3 path, alternative to FSx)
  s3_bucket_name = "${local.name}-model-storage-${data.aws_caller_identity.current.account_id}-${var.region}"

  tags = {}
}
