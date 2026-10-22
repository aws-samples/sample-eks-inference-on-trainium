################################################################################
# Device Plugin(s)
################################################################################
module "data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "1.33.0"

  oidc_provider_arn = module.eks.oidc_provider_arn
  # Neuron devices come from the Neuron DRA driver (helm_release.neuron below),
  # not the device plugin: the two can't run on the same node.
  enable_aws_neuron_device_plugin = false

  #---------------------------------------------------------------
  # NVIDIA GPU Operator: DCGM exporter (GPU metrics) and NFD (GPU node labels).
  # GPUs are allocated by the NVIDIA DRA driver (helm_release.nvidia_dra_driver
  # below), so the operator's device plugin is off: the two can't manage the
  # same GPUs. Driver and container toolkit are off too, because the
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
      devicePlugin:
        enabled: false
      dcgmExporter:
        enabled: true
        env:
          # Collect GPU stats every 1s (default 30s) to match the 1s scrape.
          - name: DCGM_EXPORTER_INTERVAL
            value: "1000"
          # Attribute GPU metrics to the pods holding them through DRA claims
          # (pod/namespace labels), not device-plugin allocations.
          - name: DCGM_EXPORTER_KUBERNETES_ENABLE_DRA
            value: "true"
        serviceMonitor:
          enabled: true
          interval: 1s
          scrapeTimeout: 1s
      # Controllers (operator, NFD master/gc) on the managed node group.
      operator:
        nodeSelector:
          karpenter.sh/controller: "true"
      # DaemonSets (device plugin, DCGM exporter, ...): tolerate every taint.
      daemonsets:
        tolerations:
          - operator: Exists
      # NFD labels GPU nodes (-> nvidia.com/gpu.present), which gates the device
      # plugin; its worker isn't covered by daemonsets.tolerations.
      node-feature-discovery:
        master:
          nodeSelector:
            karpenter.sh/controller: "true"
        gc:
          nodeSelector:
            karpenter.sh/controller: "true"
        worker:
          tolerations:
            - operator: Exists
      EOT
    ]
  }

  #---------------------------------------------------------------
  # KubeRay Operator (manages RayCluster / RayService / RayJob CRDs), on the
  # managed node group.
  #---------------------------------------------------------------
  enable_kuberay_operator = true

  kuberay_operator_helm_config = {
    version = "1.7.1"
    values = [
      <<-EOT
      nodeSelector:
        karpenter.sh/controller: "true"
      EOT
    ]
  }

  depends_on = [module.eks]
}

################################################################################
# Neuron DRA driver (Dynamic Resource Allocation)
################################################################################
# Publishes every Trainium device in a ResourceSlice (DeviceClass
# neuron.aws.com) with topology attributes, so a pod can claim N *connected*
# devices (resource.aws.com/devicegroup<N>_id) - what tensor parallelism across
# devices needs on trn2.48xlarge - and set the Logical NeuronCore size per claim.
# Replaces the device plugin (aws.amazon.com/neuron): the chart skips the plugin
# when the DRA driver is on. The vllm-serving chart creates the claims.
resource "helm_release" "neuron" {
  name       = "neuron"
  repository = "oci://public.ecr.aws/neuron"
  chart      = "neuron-helm-chart"
  version    = "1.10.0"
  # The release lives in kube-system; the chart creates its own neuron-dra-driver
  # namespace for the driver (a pre-created one makes the install fail).
  namespace = "kube-system"

  values = [
    <<-EOT
    devicePlugin:
      enabled: false
    # Node problem detector: off, its Neuron health conditions aren't used here.
    npd:
      enabled: false
    draDriver:
      enabled: true
      # Tolerate every taint (the Neuron pools also carry the karpenter taint) and
      # match the neuron.amazonaws.com/neuron-device=true label every Neuron pool sets.
      tolerations:
        - operator: Exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: neuron.amazonaws.com/neuron-device
                operator: In
                values: ["true"]
    EOT
  ]

  depends_on = [module.eks]
}

################################################################################
# NVIDIA DRA driver (Dynamic Resource Allocation) for GPUs
################################################################################
# Publishes every NVIDIA GPU in a ResourceSlice (DeviceClass gpu.nvidia.com);
# the vllm-serving chart and the Ray manifests claim GPUs through it, and
# Karpenter (settings.enableDRA) provisions GPU nodes for pending claims.
# ComputeDomains (multi-node NVLink) are off: Karpenter doesn't provision for
# them. The kubelet plugin runs on nodes NFD labels as NVIDIA GPU nodes.
resource "helm_release" "nvidia_dra_driver" {
  name             = "nvidia-dra-driver-gpu"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "nvidia-dra-driver-gpu"
  version          = "25.12.0"
  namespace        = "nvidia-dra-driver-gpu"
  create_namespace = true

  values = [
    <<-EOT
    gpuResourcesEnabledOverride: true
    resources:
      gpus:
        enabled: true
      computeDomains:
        enabled: false
    kubeletPlugin:
      tolerations:
        - operator: Exists
    EOT
  ]

  depends_on = [module.data_addons]
}

################################################################################
# neuron-monitor (Neuron hardware metrics exporter; scraped via the
# neuron-monitor ServiceMonitor in observability.tf)
################################################################################
# neuron-monitor: exposes Trainium hardware metrics (NeuronCore utilization,
# memory, etc.) on :9010 as a Prometheus endpoint. Runs on every Neuron node
# (all neuron pools set neuron.amazonaws.com/neuron-device=true) and tolerates
# every taint.
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
# AWS Load Balancer Controller (on the managed node group). Reconciles Ingress
# and Service type LoadBalancer into ALBs/NLBs; IAM via EKS Pod Identity with
# the controller's standard policy.
################################################################################

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name                            = "aws-load-balancer-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = local.tags
}

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
      nodeSelector:
        karpenter.sh/controller: "true"
    EOT
  ]

  depends_on = [module.eks, module.aws_lb_controller_pod_identity]
}
