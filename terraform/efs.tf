################################################################################
# Shared Neuron compile cache: an EFS file system mounted by every pod that
# compiles or serves on Neuron, as the vLLM-Neuron remote cache
# (NEURON_LIBTORCH_REMOTE_CACHE). Compile Jobs (often on CPU nodes) publish each
# compiled graph (NEFF) into it - atomically, so concurrent compiles are safe -
# and serving pods on any node read it (read-only) instead of compiling. Same
# lifecycle as the cluster: `terraform destroy` deletes it and its cache.
#
#   EFS (access point /neuron-cache) -> PV/PVC neuron-cache (namespace default)
#     <mount>/neff/                  compiled graphs, one dir per cache key
#     <mount>/manifests/<release>/   per-compile manifest of the graphs it built
################################################################################

resource "aws_efs_file_system" "neuron_cache" {
  creation_token   = "${local.name}-neuron-cache"
  encrypted        = true
  performance_mode = "generalPurpose"
  # Throughput scales with use and is billed per GB transferred: bursts of
  # NEFF reads at serving startup, idle otherwise.
  throughput_mode = "elastic"

  tags = merge(local.tags, { Name = "${local.name}-neuron-cache" })
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.name}-efs-"
  description = "NFS from the VPC to the Neuron cache EFS mount targets"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS from the VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${local.name}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

# One mount target per AZ (private subnet), so every node mounts locally.
resource "aws_efs_mount_target" "neuron_cache" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.neuron_cache.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Root of the cache, created world-readable and root-writable: compile Jobs
# (root) write, serving pods (root, or `ray` in the Ray images) read.
resource "aws_efs_access_point" "neuron_cache" {
  file_system_id = aws_efs_file_system.neuron_cache.id

  root_directory {
    path = "/neuron-cache"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0755"
    }
  }

  tags = merge(local.tags, { Name = "${local.name}-neuron-cache" })
}

# EFS CSI driver (EKS add-on in eks.tf) permissions, via Pod Identity.
module "efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.11.0"

  name                      = "aws-efs-csi"
  attach_aws_efs_csi_policy = true

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "efs-csi-controller-sa"
    }
    node = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "efs-csi-node-sa"
    }
  }

  tags = local.tags
}

# Static PV + PVC on the access point (ReadWriteMany: every node at once).
resource "kubectl_manifest" "neuron_cache_pv" {
  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata   = { name = "neuron-cache" }
    spec = {
      capacity                      = { storage = "1Ti" } # EFS is elastic; required field only
      accessModes                   = ["ReadWriteMany"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = ""
      csi = {
        driver       = "efs.csi.aws.com"
        volumeHandle = "${aws_efs_file_system.neuron_cache.id}::${aws_efs_access_point.neuron_cache.id}"
      }
      mountOptions = ["tls"]
    }
  })
  depends_on = [module.eks, aws_efs_mount_target.neuron_cache]
}

resource "kubectl_manifest" "neuron_cache_pvc" {
  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata   = { name = "neuron-cache", namespace = "default" }
    spec = {
      accessModes      = ["ReadWriteMany"]
      storageClassName = ""
      volumeName       = "neuron-cache"
      resources        = { requests = { storage = "1Ti" } }
    }
  })
  depends_on = [kubectl_manifest.neuron_cache_pv]
}
