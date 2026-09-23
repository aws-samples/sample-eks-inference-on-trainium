################################################################################
# Ray/vLLM image warmer
#
# A DaemonSet that pre-pulls the large custom Ray + vLLM image onto every
# Karpenter node, so real Ray head/worker pods skip the multi-GB pull and start
# faster. The container does nothing but sleep - the value is purely the image
# pull that kubelet does to run it (cached for later pods via IfNotPresent).
#
# Placement:
#   - nodeSelector provisionerType=Karpenter -> all Karpenter pools, never the
#     managed node group (the MNG nodes don't carry that label).
#   - tolerations: Exists (all taints) -> lands on the neuron/gpu/karpenter
#     tainted pools too.
#   - requests no accelerator, so it never consumes a Neuron/GPU device.
################################################################################
resource "kubectl_manifest" "ray_image_warmer" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: ray-image-warmer
      namespace: kube-system
      labels:
        app: ray-image-warmer
    spec:
      selector:
        matchLabels:
          app: ray-image-warmer
      template:
        metadata:
          labels:
            app: ray-image-warmer
        spec:
          # Only Karpenter nodes (all pools set this label), never the MNG.
          nodeSelector:
            provisionerType: Karpenter
          # Tolerate every taint so it runs on the neuron/gpu/karpenter pools.
          tolerations:
            - operator: Exists
          terminationGracePeriodSeconds: 0
          containers:
            - name: warmer
              image: ${aws_ecr_repository.ray_vllm.repository_url}:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c", "sleep infinity"]
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  cpu: 50m
                  memory: 64Mi
  YAML
  depends_on = [module.eks, aws_ecr_repository.ray_vllm]
}
