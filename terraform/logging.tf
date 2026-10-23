################################################################################
# Logging: Fluent Bit (aws-for-fluent-bit) on every node ships container logs to
# CloudWatch Logs, so a pod's logs outlive its node (Karpenter consolidation,
# Capacity Block end). One log group, one stream per container:
#   /aws/eks/<name>/containers   <namespace>.<pod>.<container>
# Query with CloudWatch Logs Insights. Grafana stays metrics-only.
################################################################################

resource "aws_cloudwatch_log_group" "containers" {
  name              = "/aws/eks/${local.name}/containers"
  retention_in_days = 14

  tags = local.tags
}

# Write-only to that one log group (the group itself is Terraform's, so
# retention applies and destroy removes it).
resource "aws_iam_policy" "fluent_bit" {
  name        = "${local.iam_name}-fluent-bit"
  description = "Fluent Bit: write container logs to ${aws_cloudwatch_log_group.containers.name}."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
      ]
      Resource = [
        aws_cloudwatch_log_group.containers.arn,
        "${aws_cloudwatch_log_group.containers.arn}:*",
      ]
    }]
  })
}

module "fluent_bit_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name = "fluent-bit"

  additional_policy_arns = {
    Logs = aws_iam_policy.fluent_bit.arn
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-for-fluent-bit"
    }
  }

  tags = local.tags
}

resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = "0.2.0"
  namespace  = "kube-system"

  values = [
    <<-EOT
    serviceAccount:
      create: true
      name: aws-for-fluent-bit
    cloudWatchLogs:
      enabled: true
      region: ${local.region}
      logGroupName: ${aws_cloudwatch_log_group.containers.name}
      autoCreateGroup: false
      logStreamPrefix: "node-"
      logStreamTemplate: $kubernetes['namespace_name'].$kubernetes['pod_name'].$kubernetes['container_name']
    # Join Python tracebacks (vLLM, Ray) into one event.
    additionalFilters: |
      [FILTER]
          Name                  multiline
          Match                 kube.*
          multiline.key_content log
          multiline.parser      python
    # Every node, including the tainted Karpenter and accelerator pools.
    tolerations:
      - operator: Exists
    priorityClassName: system-node-critical
    EOT
  ]

  depends_on = [module.eks, module.fluent_bit_pod_identity]
}
