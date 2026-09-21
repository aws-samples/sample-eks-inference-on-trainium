module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.34"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  # To facilitate easier interaction for demonstration purposes
  cluster_endpoint_public_access = true

  # Gives the Terraform identity admin access to the cluster
  # which will allow deploying resources into the cluster
  enable_cluster_creator_admin_permissions = true

  # These will become the default in the next major version of the module
  bootstrap_self_managed_addons   = false
  enable_irsa                     = false
  enable_security_groups_for_pods = false

  # EKS Addons
  cluster_addons = {
    coredns                   = {}
    eks-node-monitoring-agent = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    node_repair_config = {
      enabled = true
    }
  }

  eks_managed_node_groups = {
    # This node group is for core addons such as CoreDNS
    default = {
      instance_types = ["m5.xlarge"]

      min_size     = 0
      max_size     = 3
      desired_size = 2

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 256
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }

    }

  }

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })


  tags = local.tags
}