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

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  # renovate: datasource=github-releases depName=aws/karpenter-provider-aws
  version = "1.1.5"
  wait    = true

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
  depends_on = [
    module.eks,
    module.karpenter
  ]
}

# Apply every Karpenter NodeClass / NodePool manifest under ./karpenter.
# Each YAML is rendered with templatefile so var interpolation still works.
resource "kubectl_manifest" "karpenter" {
  for_each = fileset("${path.module}/karpenter", "*.yaml")

  server_side_apply = true
  yaml_body = templatefile("${path.module}/karpenter/${each.value}", {
    name            = local.name
    x86_ami_name    = var.x86_ami_name
    neuron_ami_name = var.neuron_ami_name
    gpu_ami_name    = var.gpu_ami_name
  })

  depends_on = [
    helm_release.karpenter
  ]
}
