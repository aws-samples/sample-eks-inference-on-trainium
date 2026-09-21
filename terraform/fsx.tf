# =============================================================================
# RETIRED: FSx for Lustre model cache — replaced by the S3 model cache
# (see s3.tf, pull-to-s3.tf, model-reader.tf). Serving now reads from S3.
#
# Left commented out on purpose: `terraform apply` will DELETE these resources
# (FSx CSI driver, Lustre filesystem, PV/PVC, pod identity). Kept here for
# reference during the migration; delete this file once S3 is confirmed.
#
# NOTE before applying: any pod still mounting the `fsx-models` PVC (e.g. the
# `mistral-fsx` test deployment or leftover `fsx-inspector`) must be deleted
# first, or the PVC/PV destroy will hang.
# =============================================================================

/*
################################################################################
# FSx CSI Driver
################################################################################

resource "helm_release" "aws_fsx_csi_driver" {
  name       = "aws-fsx-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-fsx-csi-driver"
  chart      = "aws-fsx-csi-driver"
  version    = "1.10.0"
  namespace  = "kube-system"
  wait       = false

  values = [
    <<-EOT
      controller:
        region: ${local.region}
    EOT
  ]

  # Without this, Terraform starts the Helm install immediately after the
  # cluster endpoint is available and races the EKS Access Entry authorization
  # propagation -> the chart's first kube API call (GET serviceaccounts in
  # kube-system) is denied with 403. Every other helm_release in this config
  # depends on module.eks for exactly this reason; this one was the outlier.
  depends_on = [module.eks, module.aws_fsx_csi_driver_pod_identity]
}

module "aws_fsx_csi_driver_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.10.0"

  name = "aws-fsx-csi-driver"

  attach_aws_fsx_lustre_csi_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "fsx-csi-controller-sa"
    }
  }

  tags = local.tags
}

################################################################################
# FSx for Lustre Persistent 2 file system
################################################################################

locals {
  fsx_storage_capacity = 1200
}

resource "time_sleep" "wait_for_security_groups" {
  depends_on      = [module.eks]
  create_duration = "30s"
}


module "fsx_lustre" {
  source  = "terraform-aws-modules/fsx/aws//modules/lustre"
  version = "1.2.0"

  name = local.name

  # File system
  automatic_backup_retention_days = 0
  deployment_type                 = "PERSISTENT_2"
  file_system_type_version        = "2.15"

  log_configuration = {
    level = "WARN_ERROR"
  }

  per_unit_storage_throughput = 250
  metadata_configuration = {
    mode = "USER_PROVISIONED"
    iops = 3000
  }

  storage_capacity = local.fsx_storage_capacity
  storage_type     = "SSD"
  # File systems currently support only one subnet
  subnet_ids = slice(module.vpc.private_subnets, 0, 1)

  # Security group
  security_group_name = local.name
  security_group_ingress_rules = {
    in_988 = {
      description                  = "Allow FSx clients from the EKS nodes"
      from_port                    = 988
      to_port                      = 988
      referenced_security_group_id = module.eks.node_security_group_id
    }
    in_1018_1023 = {
      description                  = "Allow FSx clients from the EKS nodes"
      from_port                    = 1018
      to_port                      = 1023
      referenced_security_group_id = module.eks.node_security_group_id
    }
  }

  depends_on = [time_sleep.wait_for_security_groups]
  tags = local.tags

}

################################################################################
# FSx PersistentVolume and PersistentVolumeClaim - Static Provisioning
################################################################################

locals {
  volume_name = "fsx-models"
}

resource "kubectl_manifest" "fsx_pvc" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ${local.volume_name}
    spec:
      accessModes:
        - ReadWriteMany
      resources:
          requests:
            storage: ${local.fsx_storage_capacity}Gi
      volumeName: ${local.volume_name}
  YAML
}

resource "kubectl_manifest" "fsx_pv" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ${local.volume_name}
    spec:
      capacity:
        storage: ${local.fsx_storage_capacity}Gi
      volumeMode: Filesystem
      accessModes:
        - ReadWriteMany
      mountOptions:
        - flock
      persistentVolumeReclaimPolicy: Retain
      csi:
        driver: fsx.csi.aws.com
        volumeHandle: ${module.fsx_lustre.file_system_id}
        volumeAttributes:
          dnsname: ${module.fsx_lustre.file_system_dns_name}
          mountname: ${module.fsx_lustre.file_system_mount_name}
  YAML
}
*/
