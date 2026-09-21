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
    # Enable default scheduler
    values = [
      <<-EOT
      devicePlugin:
        tolerations:
        - key: aws.amazon.com/neuron
          operator: Exists
          effect: NoSchedule
      scheduler:
        enabled: true
      npd:
        enabled: false
      EOT
    ]
  }
  depends_on = [helm_release.aws_load_balancer_controller]
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
    EOT
  ]

  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
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

  depends_on = [module.eks, helm_release.kube_prometheus_stack, helm_release.aws_load_balancer_controller]
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

  depends_on = [module.eks, helm_release.grafana_operator, helm_release.kube_prometheus_stack]
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

resource "kubectl_manifest" "vllm_grafana_dashboard_config" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: vllm-grafana-dashboard-config
      namespace: monitoring
    data:
      vllm-dashboard.json: ${jsonencode(file("${path.module}/grafana-dashboards/vllm-dashboard.json"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "ray_default_grafana_dashboard_config" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ray-grafana-default-dashboard-config
      namespace: monitoring
    data:
      ray-default-grafana-dashboard.json: ${jsonencode(file("${path.module}/grafana-dashboards/ray-default-grafana-dashboard.json"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "ray_serve_grafana_dashboard_config" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ray-grafana-serve-dashboard-config
      namespace: monitoring
    data:
      ray-serve-grafana-dashboard.json: ${jsonencode(file("${path.module}/grafana-dashboards/ray-serve-grafana-dashboard.json"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "ray_serve_deployment_grafana_dashboard_config" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ray-grafana-serve-deployment-dashboard-config
      namespace: monitoring
    data:
      ray-serve-deployment-grafana-dashboard.json: ${jsonencode(file("${path.module}/grafana-dashboards/ray-serve-deployment-grafana-dashboard.json"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}


resource "kubectl_manifest" "neuron_monitor_grafana_dashboard_config" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: nm-dashboard-config
      namespace: monitoring
    data:
      neuron-monitor-grafana-dashboard.json: ${jsonencode(file("${path.module}/grafana-dashboards/neuron-monitor-grafana-dashboard.json"))}
  YAML

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}
