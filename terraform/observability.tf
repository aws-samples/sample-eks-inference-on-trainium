################################################################################
# Observability: the Prometheus/Grafana stack (kube-prometheus-stack +
# grafana-operator), what Prometheus scrapes (ServiceMonitors / PodMonitors for
# vLLM, neuron-monitor, Ray), and the Grafana dashboards. The metric exporters
# themselves (neuron-monitor, DCGM via the GPU operator) live in addons.tf.
################################################################################

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
      # Second Prometheus datasource tuned for the 1s scrapes (vLLM, neuron-monitor,
      # DCGM): Grafana's $__rate_interval follows timeInterval, so those dashboards
      # get 1s-resolution rate windows. The default datasource stays at the global
      # 30s so the stock Kubernetes dashboards keep working.
      additionalDataSources:
        - name: Prometheus (1s)
          uid: prometheus-1s
          type: prometheus
          access: proxy
          url: http://kube-prometheus-stack-prometheus.monitoring:9090/
          isDefault: false
          jsonData:
            httpMethod: POST
            timeInterval: 1s
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        # Bounded so it can't starve the control-plane pods it shares the
        # managed node group with (~0.4 GiB at the 1s vLLM/Neuron/DCGM scrapes).
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            memory: 4Gi
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

################################################################################
# Scrape configs
################################################################################
# Every ServiceMonitor / PodMonitor under ./scrape-configs (what Prometheus
# scrapes: vLLM via the metrics-enabled convention, neuron-monitor, Ray). Drop a
# new *.yaml in that folder and it is applied on the next `terraform apply`.
resource "kubectl_manifest" "scrape_configs" {
  for_each = fileset("${path.module}/scrape-configs", "*.yaml")

  server_side_apply = true
  yaml_body         = file("${path.module}/scrape-configs/${each.value}")
  depends_on = [
    helm_release.kube_prometheus_stack,
    kubectl_manifest.neuron_monitor_service,
  ]
}

# One GrafanaDashboard per dashboard JSON under ./grafana-dashboards. The JSON is
# embedded inline via spec.json (yamlencode handles the multi-line string), so no
# ConfigMap is needed. grafana-operator loads it into the external-grafana instance.
# Drop a new *.json in that folder and it is applied on the next `terraform apply`.
resource "kubectl_manifest" "grafana_dashboards" {
  for_each = fileset("${path.module}/grafana-dashboards", "*.json")

  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaDashboard"
    metadata = {
      name      = trimsuffix(each.value, ".json")
      namespace = "monitoring"
      labels    = { dashboards = "external-grafana" }
    }
    spec = {
      instanceSelector = { matchLabels = { dashboards = "external-grafana" } }
      json             = file("${path.module}/grafana-dashboards/${each.value}")
    }
  })
  depends_on = [kubectl_manifest.external_grafana]
}
