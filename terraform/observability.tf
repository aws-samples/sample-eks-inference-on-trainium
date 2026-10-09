################################################################################
# Observability wiring for LLM inference (Neuron HW metrics, Ray/Serve metrics,
# and Grafana dashboards). The base stack (Prometheus, Grafana, grafana-operator)
# lives in data-addons.tf; this file pre-provisions the scrapers + dashboards so
# they are ready without manual kubectl.
################################################################################

# neuron-monitor: exposes Trainium/Inferentia hardware metrics (NeuronCore
# utilization, memory, etc.) on :9010 as a Prometheus endpoint. Runs on every
# Neuron node (all neuron pools set neuron.amazonaws.com/neuron-device=true) and
# tolerates both the accelerator and the karpenter taints.
resource "kubectl_manifest" "neuron_monitor" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: neuron-monitor
      namespace: monitoring
      labels:
        app: neuron-monitor
    spec:
      selector:
        matchLabels:
          app: neuron-monitor
      template:
        metadata:
          labels:
            app: neuron-monitor
          annotations:
            prometheus.io/scrape: "true"
            prometheus.io/port: "9010"
        spec:
          # hostPID: neuron-monitor reads /proc/<pid>/stat of the Neuron runtime
          #   processes (vLLM) for the neuron_runtime_* vcpu/memory metrics.
          # hostNetwork: reach IMDS so instance_id/type/az/region labels populate
          #   (the Neuron Grafana dashboard groups by them).
          hostPID: true
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: app
              image: public.ecr.aws/neuron/neuron-monitor:1.3.0
              command: ["/bin/sh"]
              args:
                - "-c"
                - "neuron-monitor | neuron-monitor-prometheus.py --port 9010"
              ports:
                - name: metrics
                  containerPort: 9010
                  hostPort: 9010
              resources:
                limits: { cpu: 200m, memory: 200Mi }
                requests: { cpu: 100m, memory: 100Mi }
              volumeMounts:
                - name: dev
                  mountPath: /dev
              securityContext:
                privileged: true
          tolerations:
            - key: aws.amazon.com/neuron
              operator: Exists
              effect: NoSchedule
            - key: karpenter
              operator: Exists
              effect: NoSchedule
          nodeSelector:
            neuron.amazonaws.com/neuron-device: "true"
          volumes:
            - name: dev
              hostPath:
                path: /dev
          restartPolicy: Always
  YAML
  depends_on        = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "neuron_monitor_service" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: neuron-monitor
      namespace: monitoring
      labels:
        app: neuron-monitor
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9010"
    spec:
      clusterIP: None
      ports:
        - name: metrics
          port: 9010
          protocol: TCP
      selector:
        app: neuron-monitor
  YAML
  depends_on        = [kubectl_manifest.neuron_monitor]
}

resource "kubectl_manifest" "neuron_monitor_servicemonitor" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: neuron-monitor
      namespace: monitoring
      labels:
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        matchNames: ["monitoring"]
      selector:
        matchLabels:
          app: neuron-monitor
      endpoints:
        - port: metrics
          interval: 30s
          path: /metrics
          scheme: http
  YAML
  depends_on        = [kubectl_manifest.neuron_monitor_service]
}

# Cluster-wide convention: any Service labeled `metrics: enabled` with a port
# named `http` is scraped at /metrics (e.g. the standalone vLLM deployments).
# Prometheus Operator ignores prometheus.io/* annotations, so workloads opt in
# with the label instead of needing their own monitor.
resource "kubectl_manifest" "metrics_enabled_servicemonitor" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: metrics-enabled
      namespace: monitoring
      labels:
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        any: true
      selector:
        matchLabels:
          metrics: enabled
      endpoints:
        - port: http
          path: /metrics
          interval: 15s
          scheme: http
  YAML
  depends_on        = [helm_release.kube_prometheus_stack]
}

# Ray head + worker PodMonitors so Prometheus scrapes Ray, autoscaler, dashboard,
# and Ray Serve (incl. vLLM-on-Ray) metrics from the RayService pods in default.
resource "kubectl_manifest" "ray_head_monitor" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: ray-head-monitor
      namespace: monitoring
      labels:
        release: kube-prometheus-stack
    spec:
      jobLabel: ray-head
      namespaceSelector:
        matchNames: ["default"]
      selector:
        matchLabels:
          ray.io/node-type: head
      podMetricsEndpoints:
        - port: metrics
          relabelings:
            - action: replace
              sourceLabels: ["__meta_kubernetes_pod_label_ray_io_cluster"]
              targetLabel: ray_io_cluster
        - port: as-metrics
          relabelings:
            - action: replace
              sourceLabels: ["__meta_kubernetes_pod_label_ray_io_cluster"]
              targetLabel: ray_io_cluster
        - port: dash-metrics
          relabelings:
            - action: replace
              sourceLabels: ["__meta_kubernetes_pod_label_ray_io_cluster"]
              targetLabel: ray_io_cluster
  YAML
  depends_on        = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "ray_workers_monitor" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: ray-workers-monitor
      namespace: monitoring
      labels:
        release: kube-prometheus-stack
    spec:
      jobLabel: ray-workers
      namespaceSelector:
        matchNames: ["default"]
      selector:
        matchLabels:
          ray.io/node-type: worker
      podMetricsEndpoints:
        - port: metrics
          relabelings:
            - sourceLabels: ["__meta_kubernetes_pod_label_ray_io_cluster"]
              targetLabel: ray_io_cluster
  YAML
  depends_on        = [helm_release.kube_prometheus_stack]
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
