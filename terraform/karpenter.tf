module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.24"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  iam_role_name                   = "${module.eks.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix        = false
  iam_policy_name                 = "${module.eks.cluster_name}-karpenter-controller"
  iam_policy_use_name_prefix      = false
  node_iam_role_name              = "${module.eks.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix   = false
  queue_name                      = "${module.eks.cluster_name}-karpenter"
  rule_name_prefix                = "eks-workshop"
  create_pod_identity_association = true

  tags = local.tags
}

# Extra IAM the submodule's controller policy does not grant:
#   - iam:ListInstanceProfiles: Karpenter 1.14+ uses it during instance-profile
#     reconciliation, without it no node launches.
#   - ec2:DescribeCapacityReservations: required for
#     capacityReservationSelectorTerms (ML Capacity Blocks on the trn2 pool).
#   - ec2:DescribeInstanceStatus: Karpenter 1.15+ instance status health checks
#     (interruption controller).
resource "aws_iam_role_policy" "karpenter_extras" {
  name = "karpenter-extras"
  role = module.karpenter.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:ListInstanceProfiles",
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeInstanceStatus",
        ]
        Resource = "*"
      },
      {
        # RunInstances into an ML Capacity Block: the submodule's RunInstances
        # policy does not include the capacity-reservation resource ARN.
        Effect   = "Allow"
        Action   = ["ec2:RunInstances"]
        Resource = ["arn:aws:ec2:*:*:capacity-reservation/*"]
      }
    ]
  })
}

# CRDs are shipped as a separate chart because `helm upgrade` never updates the
# CRDs bundled in the controller chart. This chart owns/upgrades the NodePool /
# EC2NodeClass / NodeClaim CRDs - required for newer fields like spec.replicas.
resource "helm_release" "karpenter_crd" {
  name                = "karpenter-crd"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter-crd"
  version             = "1.15.0"
  wait                = true

  lifecycle {
    ignore_changes = [repository_password]
  }
  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  # renovate: datasource=github-releases depName=aws/karpenter-provider-aws
  version = "1.15.0"
  wait    = true

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
      # StaticCapacity is Alpha and off by default; required for NodePool
      # spec.replicas (the static Capacity Block pools) to actually create nodes.
      # Chart values key is camelCase (staticCapacity); it renders to
      # FEATURE_GATES=...StaticCapacity=true... on the controller.
      featureGates:
        staticCapacity: true
      # Dynamic Resource Allocation (alpha, Karpenter 1.15+): provision nodes for
      # pods that claim NVIDIA GPUs through ResourceClaims (enables the
      # draNVIDIAGPU / draEFA gates). Static Capacity Block pools need no Karpenter
      # support for DRA (Karpenter doesn't simulate them), so Neuron claims work
      # either way.
      enableDRA: true
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
  # module.vpc: module.eks only references the VPC ID and subnets, so without
  # this the NAT gateway/routes can be destroyed while the controller still
  # needs egress to the EC2 API to terminate its nodes.
  depends_on = [
    module.vpc,
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd
  ]
}

# Karpenter manifests under ./karpenter:
#   nodeclasses/*.yaml                    EC2NodeClasses: x86-cpu-karpenter, neuron, gpu
#   nodepools/*.yaml                      dynamic NodePools: x86-cpu-karpenter, gpu-g6e
#   capacity-block-nodepool.yaml.tftpl    one static NodePool per var.capacity_blocks_nodepools entry
# Each Capacity Block's reservation ID is added to its hardware's NodeClass.
locals {
  karpenter_template_vars = {
    name                            = local.name
    x86_ami_name                    = var.x86_ami_name
    neuron_ami_name                 = var.neuron_ami_name
    gpu_ami_name                    = var.gpu_ami_name
    neuron_capacity_reservation_ids = [for k, b in var.capacity_blocks_nodepools : b.reservation_id if b.hardware == "neuron"]
    gpu_capacity_reservation_ids    = [for k, b in var.capacity_blocks_nodepools : b.reservation_id if b.hardware == "gpu"]
  }
}

resource "kubectl_manifest" "karpenter" {
  for_each = fileset("${path.module}/karpenter", "{nodeclasses,nodepools}/*.yaml")

  server_side_apply = true
  # On destroy, block until finalizers clear (Karpenter has terminated the
  # nodes) so the controller isn't uninstalled while instances are still up.
  wait      = true
  yaml_body = templatefile("${path.module}/karpenter/${each.value}", local.karpenter_template_vars)

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_capacity_block" {
  for_each = var.capacity_blocks_nodepools

  server_side_apply = true
  wait              = true
  yaml_body = templatefile("${path.module}/karpenter/capacity-block-nodepool.yaml.tftpl", {
    pool_name      = each.key
    reservation_id = each.value.reservation_id
    instance_type  = each.value.instance_type
    az             = each.value.az
    node_count     = each.value.node_count
    hardware       = each.value.hardware
  })

  # NodeClasses first (they carry the reservation selector terms).
  depends_on = [
    kubectl_manifest.karpenter
  ]
}
