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
    # CoreDNS (a Deployment) runs on the managed node group. The DaemonSet
    # addons below tolerate every taint and run on every node.
    coredns = {
      configuration_values = jsonencode({
        nodeSelector = { "karpenter.sh/controller" = "true" }
      })
    }
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

      tags = {
        "auto-stop"   = "no"
        "auto-delete" = "no"
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
# EKS does not propagate node group tags to the underlying ASG, and the account's
# SpringClean sweep scales untagged ASGs to 0 - which takes down the Karpenter
# controller and every system pod with it. Tag the ASG directly.
resource "aws_autoscaling_group_tag" "default_node_group" {
  for_each = toset(["auto-stop", "auto-delete"])

  autoscaling_group_name = module.eks.eks_managed_node_groups["default"].node_group_autoscaling_group_names[0]

  tag {
    key                 = each.key
    value               = "no"
    propagate_at_launch = true
  }
}
