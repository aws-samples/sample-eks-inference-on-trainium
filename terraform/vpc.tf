data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  # https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html#network-requirements-subnets
  exclude_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]
}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = data.aws_availability_zones.available.names
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.18.1"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + 1)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
