################################################################################
# AWS Load Balancer Controller
################################################################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.13.0"

  values = [
    <<-EOT
      clusterName: ${module.eks.cluster_name}
      region: ${local.region}
      vpcId: ${module.vpc.vpc_id}
      enableServiceMutatorWebhook: false
    EOT
  ]

  depends_on = [module.eks, module.aws_lb_controller_pod_identity]
}

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "aws-load-balancer-controller"

  attach_aws_lb_controller_policy = false

  additional_policy_arns = {
    ALBControllerPolicy = aws_iam_policy.alb_controller_policy.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = local.tags

  depends_on = [module.eks, aws_iam_policy.alb_controller_policy]
}


resource "aws_iam_policy" "alb_controller_policy" {
  name        = "${module.eks.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  description = "Policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeAvailabilityZones",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:ModifyNetworkInterfaceAttribute",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:SetWebAcl",
          "iam:CreateServiceLinkedRole"
        ]
        Resource = "*"
      }
    ]
  })

  depends_on = [module.eks]
}
