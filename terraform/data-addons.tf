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
        serviceMonitor:
          enabled: true
      daemonsets:
        tolerations:
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
# Observability Stack (Kube Prometheus Stack + Grafana Operator)
################################################################################
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "69.7.4"
  namespace        = "monitoring"
  create_namespace = true
  wait             = false

  values = [
    <<-EOT
    grafana:
      enabled: true
      defaultDashboardsEnabled: true
      adminPassword: "notforproductionuse"
      service:
        type: ClusterIP
        port: 3000
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
    prometheus-node-exporter:
      # node-exporter is a DaemonSet that must run on every node, including the
      # tainted Karpenter pools. Tolerate all taints so metrics cover all nodes.
      tolerations:
        - operator: Exists
    EOT
  ]

  depends_on = [module.eks]
}


resource "helm_release" "grafana_operator" {
  name       = "grafana-operator"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana-operator"
  version    = "5.16.0"
  wait       = false

  values = [
    <<-EOT
    operator:
      scanAllNamespaces: true
    EOT
  ]

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}


resource "kubectl_manifest" "grafana_admin_credentials" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: grafana-admin-credentials
      namespace: monitoring
    data:
      admin-user: ${base64encode("admin")}
      admin-password: ${base64encode("notforproductionuse")}
  YAML

  depends_on = [module.eks, helm_release.grafana_operator]
}


resource "kubectl_manifest" "external_grafana" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: grafana.integreatly.org/v1beta1
    kind: Grafana
    metadata:
      name: external-grafana
      namespace: monitoring
      labels:
        dashboards: external-grafana
    spec:
      external:
        url: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:3000
        adminUser:
          name: grafana-admin-credentials
          key: admin-user
        adminPassword:
          name: grafana-admin-credentials
          key: admin-password
  YAML

  depends_on = [module.eks, helm_release.grafana_operator, kubectl_manifest.grafana_admin_credentials, helm_release.kube_prometheus_stack]
}

# Create a ConfigMap for every Grafana dashboard JSON under ./grafana-dashboards.
# The `grafana_dashboard` label lets the kube-prometheus-stack Grafana sidecar
# discover and import each dashboard automatically. Drop a new *.json in that
# folder and it is applied on the next `terraform apply` - no code change needed.
resource "kubectl_manifest" "grafana_dashboards" {
  for_each = fileset("${path.module}/grafana-dashboards", "*.json")

  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${trimsuffix(each.value, ".json")}
      namespace: monitoring
      labels:
        grafana_dashboard: "1"
    data:
      ${each.value}: ${jsonencode(file("${path.module}/grafana-dashboards/${each.value}"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}
