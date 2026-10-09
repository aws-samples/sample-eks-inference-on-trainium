################################################################################
# Device Plugin(s)
################################################################################
module "data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "1.33.0"

  oidc_provider_arn = module.eks.oidc_provider_arn
  #---------------------------------------------------------------
  # Neuron Add-on
  #---------------------------------------------------------------
  enable_aws_neuron_device_plugin = true

  aws_neuron_device_plugin_helm_config = {
    version = "0.1.0"
    # Enable default scheduler
    values = [
      <<-EOT
      devicePlugin:
        tolerations:
        - key: aws.amazon.com/neuron
          operator: Exists
          effect: NoSchedule
        - key: karpenter
          operator: Exists
          effect: NoSchedule
      # The chart's default nodeAffinity is a hardcoded instance-type allowlist
      # that omits trn2.48xlarge (and any newer type), so the plugin never lands
      # on trn2 and no aws.amazon.com/neuron devices are advertised. Replace it
      # with a label match on neuron.amazonaws.com/neuron-device=true, which
      # Karpenter sets on every neuron pool (trn1/trn2/inf2) - future-proof.
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: neuron.amazonaws.com/neuron-device
                operator: In
                values: ["true"]
      scheduler:
        enabled: true
      npd:
        enabled: false
      EOT
    ]
  }

  #---------------------------------------------------------------
  # NVIDIA GPU Operator (provides the GPU device plugin + DCGM exporter
  # for GPU metrics). Driver and container toolkit are disabled because the
  # EKS-optimized NVIDIA AMI already ships them.
  #---------------------------------------------------------------
  enable_nvidia_gpu_operator = true

  nvidia_gpu_operator_helm_config = {
    version = "v26.7.0"
    values = [
      <<-EOT
      driver:
        enabled: false
      toolkit:
        enabled: false
      dcgmExporter:
        enabled: true
        # Collect GPU stats every 1s (default 30s) to match the 1s scrape.
        env:
          - name: DCGM_EXPORTER_INTERVAL
            value: "1000"
        serviceMonitor:
          enabled: true
          interval: 1s
          scrapeTimeout: 1s
      daemonsets:
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
          - key: karpenter
            operator: Exists
            effect: NoSchedule
      # NFD labels GPU nodes (-> nvidia.com/gpu.present), which gates the device
      # plugin; its worker isn't covered by daemonsets.tolerations, and the chart
      # default doesn't tolerate the Karpenter pools' `karpenter` taint.
      node-feature-discovery:
        worker:
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Equal
              value: ""
              effect: NoSchedule
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
            - key: karpenter
              operator: Exists
              effect: NoSchedule
      EOT
    ]
  }

  #---------------------------------------------------------------
  # KubeRay Operator (manages RayCluster / RayService / RayJob CRDs).
  # Runs as a controller Deployment, so it stays on the managed node group.
  #---------------------------------------------------------------
  enable_kuberay_operator = true

  kuberay_operator_helm_config = {
    version = "1.7.1"
  }

  depends_on = [module.eks]
}

################################################################################
# neuron-monitor (Neuron hardware metrics exporter; scraped via the
# neuron-monitor ServiceMonitor in observability.tf)
################################################################################
# neuron-monitor: exposes Trainium/Inferentia hardware metrics (NeuronCore
# utilization, memory, etc.) on :9010 as a Prometheus endpoint. Runs on every
# Neuron node (all neuron pools set neuron.amazonaws.com/neuron-device=true) and
# tolerates both the accelerator and the karpenter taints.
resource "kubectl_manifest" "neuron_monitor" {
  server_side_apply = true
  # Don't block the apply on the DaemonSet rollout: it only reaches every
  # matching node eventually (nodes come and go with Karpenter), and a stale
  # rollout wait has hung applies indefinitely.
  wait_for_rollout = false
  yaml_body        = file("${path.module}/manifests/neuron-monitor-daemonset.yaml")
  depends_on       = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "neuron_monitor_service" {
  server_side_apply = true
  yaml_body         = file("${path.module}/manifests/neuron-monitor-service.yaml")
  depends_on        = [kubectl_manifest.neuron_monitor]
}


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