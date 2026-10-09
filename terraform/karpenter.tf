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
#   - iam:ListInstanceProfiles: Karpenter 1.14 uses it during instance-profile
#     reconciliation, without it no node launches.
#   - ec2:DescribeCapacityReservations: required for
#     capacityReservationSelectorTerms (ML Capacity Blocks on the trn2 pool).
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
  version             = "1.14.1"
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
  version = "1.14.1"
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
      # spec.replicas (the neuron-trn1 static pool) to actually create nodes.
      # Chart values key is camelCase (staticCapacity); it renders to
      # FEATURE_GATES=...StaticCapacity=true... on the controller.
      featureGates:
        staticCapacity: true
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
  depends_on = [
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd
  ]
}

locals {
  # Capacity Blocks each NodeClass may launch into. Karpenter only uses one when
  # a NodePool's requirements (instance type, AZ, capacity-type reserved) match.
  neuron_capacity_reservation_ids = [for k, b in var.capacity_blocks : b.reservation_id if b.hardware == "neuron"]
  gpu_capacity_reservation_ids    = [for k, b in var.capacity_blocks : b.reservation_id if b.hardware == "gpu"]
}

# Karpenter manifests, all under ./karpenter:
#   nodeclasses/*.yaml        EC2NodeClasses (x86, neuron, gpu)
#   nodepools/*.yaml          on-demand / static NodePools
#   capacity-blocks/*.tftpl   template for the var.capacity_blocks NodePools
# Keyed by file name (not path), so moving files between folders doesn't
# recreate the live objects. Each YAML is rendered with templatefile.
locals {
  karpenter_manifests = {
    for f in fileset("${path.module}/karpenter", "{nodeclasses,nodepools}/*.yaml") : basename(f) => f
  }
  karpenter_template_vars = {
    name                            = local.name
    x86_ami_name                    = var.x86_ami_name
    neuron_ami_name                 = var.neuron_ami_name
    gpu_ami_name                    = var.gpu_ami_name
    neuron_capacity_reservation_ids = local.neuron_capacity_reservation_ids
    gpu_capacity_reservation_ids    = local.gpu_capacity_reservation_ids
  }
}

resource "kubectl_manifest" "karpenter" {
  for_each = local.karpenter_manifests

  server_side_apply = true
  yaml_body         = templatefile("${path.module}/karpenter/${each.value}", local.karpenter_template_vars)

  depends_on = [
    helm_release.karpenter
  ]
}

# One static NodePool per Capacity Block (var.capacity_blocks), keeping every
# instance in the block running.
resource "kubectl_manifest" "karpenter_capacity_block" {
  for_each = var.capacity_blocks

  server_side_apply = true
  yaml_body = templatefile("${path.module}/karpenter/capacity-blocks/nodepool.yaml.tftpl", {
    pool_name       = each.key
    reservation_id  = each.value.reservation_id
    az              = each.value.az
    instance_type   = each.value.instance_type
    instance_family = split(".", each.value.instance_type)[0]
    node_count      = each.value.node_count
    hardware        = each.value.hardware
    node_class      = each.value.hardware
    expire_after    = each.value.expire_after
  })

  # NodeClasses first (they carry the reservation selector terms).
  depends_on = [
    kubectl_manifest.karpenter
  ]
}
