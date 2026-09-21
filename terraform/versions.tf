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
