module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.24"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  iam_role_name                   = "${module.eks.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix        = false
  iam_policy_name                 = "${module.eks.cluster_name}-karpenter-controller"
  iam_policy_use_name_prefix      = false
  node_iam_role_name              = "${module.eks.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix   = false
  queue_name                      = "${module.eks.cluster_name}-karpenter"
  rule_name_prefix                = "eks-workshop"
  create_pod_identity_association = true

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  # renovate: datasource=github-releases depName=aws/karpenter-provider-aws
  version = "1.1.5"
  wait    = true

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
  depends_on = [
    module.eks,
    module.karpenter
  ]
}

resource "kubectl_manifest" "mixed-x86_nodeclass" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: x86-cpu-karpenter
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - name: ${var.x86_ami_name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            deleteOnTermination: true
            encrypted: true
            volumeSize: 200Gi
            volumeType: gp3
      detailedMonitoring: true
      role: "genai-workshop-karpenter-node"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
        - tags:
            kubernetes.io/cluster/genai-workshop: "owned"
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
            kubernetes.io/role/internal-elb: "1"
      tags:
        karpenter.sh/discovery: "genai-workshop"
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}


resource "kubectl_manifest" "mixed-x86_nodepool" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: x86-cpu-karpenter
    spec:
      template:
        metadata:
          labels:
            instanceType: mixed-x86
            provisionerType: Karpenter
        spec:
          requirements:
            - key: "karpenter.k8s.aws/instance-family"
              operator: In
              values: ["c5", "m5", "r5"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: Gt
              values: ["3"]
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
          expireAfter: 720h
          terminationGracePeriod: 24h
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: x86-cpu-karpenter
      limits:
        cpu: "256"
      disruption:
        consolidateAfter: 300s
        consolidationPolicy: WhenEmptyOrUnderutilized
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "trainium_nodeclass" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: trainium-trn1
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - name: ${var.trn1_ami_name}
      instanceStorePolicy: RAID0
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            deleteOnTermination: true
            encrypted: true
            volumeSize: 500Gi
            volumeType: gp3
      role: "genai-workshop-karpenter-node"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
        - tags:
            kubernetes.io/cluster/genai-workshop: owned
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
            kubernetes.io/role/internal-elb: "1"
      tags:
        karpenter.sh/discovery: "genai-workshop"
        aws-neuron: "true"
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "trainium_nodepool" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: trainium-trn1
    spec:
      template:
        metadata:
          labels:
            instanceType: trn1.2xlarge
            provisionerType: Karpenter
            neuron.amazonaws.com/neuron-device: "true"
        spec:
          taints:
            - key: aws.amazon.com/neuron
              value: "true"
              effect: "NoSchedule"
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["trn1.2xlarge"]
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
          expireAfter: 720h
          terminationGracePeriod: 24h
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: trainium-trn1
      limits:
        aws.amazon.com/neuron: 4
        cpu: 32
        memory: 128Gi
      disruption:
        consolidateAfter: 300s
        consolidationPolicy: WhenEmptyOrUnderutilized
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "trainium_trn2_nodeclass" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: trainium-trn2
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - name: ${var.trn2_ami_name}
      instanceStorePolicy: RAID0
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            deleteOnTermination: true
            encrypted: true
            volumeSize: 500Gi
            volumeType: gp3
      role: "genai-workshop-karpenter-node"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
        - tags:
            kubernetes.io/cluster/genai-workshop: owned
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "genai-workshop"
            kubernetes.io/role/internal-elb: "1"
      tags:
        karpenter.sh/discovery: "genai-workshop"
        aws-neuron: "true"
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "trainium_trn2_nodepool" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: trainium-trn2
    spec:
      template:
        metadata:
          labels:
            instanceType: trn2.48xlarge
            provisionerType: Karpenter
            neuron.amazonaws.com/neuron-device: "true"
        spec:
          taints:
            - key: aws.amazon.com/neuron
              value: "true"
              effect: "NoSchedule"
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["trn2.48xlarge"]
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
          expireAfter: 720h
          terminationGracePeriod: 24h
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: trainium-trn2
      limits:
        aws.amazon.com/neuron: 16
        cpu: 192
        memory: 2048Gi
      disruption:
        consolidateAfter: 300s
        consolidationPolicy: WhenEmptyOrUnderutilized
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}



