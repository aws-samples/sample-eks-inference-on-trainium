################################################################################
# Observability: the Prometheus/Grafana stack (kube-prometheus-stack), what
# Prometheus scrapes (ServiceMonitors / PodMonitors for vLLM, neuron-monitor,
# Ray), and the Grafana dashboards. The metric exporters
# themselves (neuron-monitor, DCGM via the GPU operator) live in addons.tf.
################################################################################

################################################################################
# Observability Stack (Kube Prometheus Stack)
################################################################################
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "69.7.4"
  namespace        = "monitoring"
  create_namespace = true
  # Also makes destroy wait until the release's resources are gone, so the LB
  # controller (depends_on below) is still running to delete Grafana's ALB.
  wait    = true
  timeout = 600

  values = [
    <<-EOT
    grafana:
      enabled: true
      defaultDashboardsEnabled: true
      # No adminPassword: the chart generates a random one into the
      # kube-prometheus-stack-grafana Secret (README: Visualization).
      # Internal ALB (AWS Load Balancer Controller), reachable only from the VPC.
      # Part of this release, so `terraform destroy` removes the ALB with it.
      ingress:
        enabled: true
        ingressClassName: alb
        hosts: []
        annotations:
          alb.ingress.kubernetes.io/scheme: internal
          alb.ingress.kubernetes.io/target-type: ip
          alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
          alb.ingress.kubernetes.io/inbound-cidrs: ${local.vpc_cidr}
          alb.ingress.kubernetes.io/healthcheck-path: /api/health
      # Load every ConfigMap labeled grafana_dashboard=1 (see grafana_dashboards
      # below) into the "Inference" folder.
      sidecar:
        dashboards:
          enabled: true
          label: grafana_dashboard
          labelValue: "1"
          folderAnnotation: grafana_folder
          provider:
            foldersFromFilesStructure: true
      nodeSelector:
        karpenter.sh/controller: "true"
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
        nodeSelector:
          karpenter.sh/controller: "true"
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
    # Controllers on the managed node group.
    alertmanager:
      alertmanagerSpec:
        nodeSelector:
          karpenter.sh/controller: "true"
    prometheusOperator:
      nodeSelector:
        karpenter.sh/controller: "true"
      admissionWebhooks:
        patch:
          nodeSelector:
            karpenter.sh/controller: "true"
    kube-state-metrics:
      nodeSelector:
        karpenter.sh/controller: "true"
    EOT
  ]

  # The LB controller must outlive this release on destroy, to delete Grafana's ALB.
  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
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

# One ConfigMap per dashboard JSON under ./grafana-dashboards, picked up by the
# Grafana dashboard sidecar (label grafana_dashboard=1). Drop a new *.json in
# that folder and it is applied on the next `terraform apply`.
resource "kubectl_manifest" "grafana_dashboards" {
  for_each = fileset("${path.module}/grafana-dashboards", "*.json")

  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name        = "dashboard-${trimsuffix(each.value, ".json")}"
      namespace   = "monitoring"
      labels      = { grafana_dashboard = "1" }
      annotations = { grafana_folder = "Inference" }
    }
    data = { (each.value) = file("${path.module}/grafana-dashboards/${each.value}") }
  })
  depends_on = [helm_release.kube_prometheus_stack]
}
