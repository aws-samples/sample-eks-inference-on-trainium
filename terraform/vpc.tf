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
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}

# Interface VPC endpoints: nodes in the private subnets reach these AWS APIs
# over private IPs instead of the NAT gateway - ECR image pulls (the multi-GB
# serving images), CloudWatch Logs (Fluent Bit), STS and EKS Auth (Pod Identity
# credentials). The S3 gateway endpoint is in s3.tf. The NAT gateway stays for
# HuggingFace, public registries and GitHub.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${local.name}-vpc-endpoints-"
  description = "HTTPS from the VPC to the interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${local.name}-vpc-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

# AWS services the private subnets reach through interface endpoints instead of
# the NAT gateway. Add ec2, sqs (Karpenter) and elasticloadbalancing (AWS Load
# Balancer Controller) for a fully private control path; each endpoint costs
# about $0.01/hr per AZ.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ecr.api", "ecr.dkr", "logs", "sts", "eks-auth"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-${each.value}" })
}
