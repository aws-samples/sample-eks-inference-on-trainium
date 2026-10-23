################################################################################
# Serving images in ECR
#
# One image per folder in container-images/: the folder is the Docker build context, its
# Dockerfile says what the image is. Add a folder to build another image, delete
# it to stop building one. CodeBuild builds each into its own ECR repository,
# <name>/<folder> (faster, private pulls from inside the VPC through the ECR
# endpoints in vpc.tf; every push is CVE-scanned).
#
# Each Dockerfile builds FROM a public image and declares
#   LABEL hardware=neuron|gpu   which nodes the image runs on (image warmer)
#
# Tags are a hash of the folder, so a change pushes
# a new tag instead of overwriting one that nodes already cached - and the
# chart's Neuron compile cache, keyed by image, starts empty for it. Output
# serving_images maps each folder to its URI:tag for the Helm releases.
################################################################################

locals {
  images_dir = "${path.module}/container-images"
  images = {
    for f in fileset(local.images_dir, "*/Dockerfile") : dirname(f) => {
      hardware = try(regex("(?m)^LABEL hardware=(\\S+)", file("${local.images_dir}/${f}"))[0], "")
      hash = sha1(join(",", [
        for g in sort(fileset("${local.images_dir}/${dirname(f)}", "**")) :
        "${g}:${filesha1("${local.images_dir}/${dirname(f)}/${g}")}"
      ]))
    }
  }
  image_tags = { for k, v in local.images : k => substr(v.hash, 0, 12) }
  image_uris = { for k in keys(local.images) : k => "${aws_ecr_repository.image[k].repository_url}:${local.image_tags[k]}" }

  # One build per image folder: the source is the folder itself (zipped to S3),
  # so its Dockerfile can COPY any file next to it. IMAGE: ECR URI:tag to push.
  buildspec = <<-EOT
    version: 0.2
    phases:
      build:
        commands:
          - aws ecr get-login-password | docker login --username AWS --password-stdin "$${IMAGE%%/*}"
          - docker build -t "$IMAGE" .
          - docker push "$IMAGE"
  EOT
  # Build sources: s3://<bucket>/codebuild/images/<folder>-<tag>.zip
  image_source_prefix = "codebuild/images"
}

resource "aws_ecr_repository" "image" {
  for_each = local.images

  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # Basic CVE scan of every pushed image (findings in the ECR console or
  # `aws ecr describe-image-scan-findings`); it doesn't block pulls.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest with KMS (the AWS managed key aws/ecr).
  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_codebuild_project" "images" {
  #checkov:skip=CKV_AWS_316:docker build/push needs the Docker daemon, which CodeBuild only runs in privileged mode. The project only builds the Dockerfiles in container-images/.
  name         = "${local.name}-serving-images"
  description  = "Build an image folder of terraform/container-images into ECR"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    # The base images are 10+ GB; LARGE has the disk and network to move them.
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  # Every build overrides the location with its folder's zip.
  source {
    type      = "S3"
    location  = "${local.s3_bucket_name}/${local.image_source_prefix}/"
    buildspec = local.buildspec
  }
}

resource "aws_iam_role" "codebuild" {
  name = "${local.iam_name}-serving-images-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken has no resource-level permissions.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # The project's build logs: /aws/codebuild/<project>.
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.images.name}",
          "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${aws_codebuild_project.images.name}:*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [for r in aws_ecr_repository.image : r.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "arn:aws:s3:::${local.s3_bucket_name}/${local.image_source_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.s3_bucket_name}"
      }
    ]
  })
}

# Build an image whenever its folder (or the buildspec) changes: zip the folder
# to S3, start the build and wait for it, so a failed build
# fails the apply. Images build in parallel. Logs: CodeBuild console, project
# <name>-serving-images.
# Rebuild one: terraform -chdir=terraform apply -replace='null_resource.build_image["vllm-neuron"]'
resource "null_resource" "build_image" {
  for_each = local.images

  triggers = {
    image     = local.image_uris[each.key]
    buildspec = sha1(local.buildspec)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      (cd "$DIR" && zip -qr - .) | aws s3 cp --region "$REGION" --no-progress - "s3://$BUCKET/$KEY"
      id=$(aws codebuild start-build --region "$REGION" --project-name "$PROJECT" \
        --source-location-override "$BUCKET/$KEY" \
        --environment-variables-override "name=IMAGE,value=$IMAGE,type=PLAINTEXT" \
        --query build.id --output text)
      echo "$IMAGE: build $id"
      while status=$(aws codebuild batch-get-builds --region "$REGION" --ids "$id" --query 'builds[0].buildStatus' --output text) \
        && [ "$status" = IN_PROGRESS ]; do sleep 20; done
      echo "$IMAGE: $status"
      [ "$status" = SUCCEEDED ]
    EOT
    environment = {
      DIR     = "${local.images_dir}/${each.key}"
      REGION  = local.region
      BUCKET  = local.s3_bucket_name
      KEY     = "${local.image_source_prefix}/${each.key}-${local.image_tags[each.key]}.zip"
      PROJECT = aws_codebuild_project.images.name
      IMAGE   = local.image_uris[each.key]
    }
  }

  lifecycle {
    # A replaced repository (e.g. a change to its encryption) starts empty, under
    # the same URI: rebuild into it.
    replace_triggered_by = [aws_ecr_repository.image[each.key]]
    precondition {
      condition     = contains(["neuron", "gpu"], each.value.hardware)
      error_message = "container-images/${each.key}/Dockerfile needs a 'LABEL hardware=neuron' or 'LABEL hardware=gpu' line."
    }
  }

  # The source zip goes to the model-storage bucket (s3_bucket_name is a plain
  # string, so Terraform doesn't see that dependency on its own).
  depends_on = [aws_iam_role_policy.codebuild, aws_s3_bucket.model_storage]
}

################################################################################
# Image warmers
#
# One DaemonSet per hardware that pre-pulls every image of that hardware (its
# Dockerfile's LABEL hardware=) from ECR onto each of its nodes as soon as the
# node joins, so compile, serving and Ray pods start from a cached image. One
# sleeping container per image; the value is the image pull kubelet does to run
# it (later pods reuse it via IfNotPresent). Images that share a base (the DLC)
# only pull their own layers after the first.
################################################################################

resource "kubectl_manifest" "image_warmer" {
  for_each = {
    for hw, node_label in {
      neuron = "neuron.amazonaws.com/neuron-device"
      gpu    = "nvidia.com/gpu"
    } : hw => node_label if length([for v in values(local.images) : v if v.hardware == hw]) > 0
  }

  server_side_apply = true
  # Don't block the apply on the rollout: nodes come and go with Karpenter.
  wait_for_rollout = false
  yaml_body = templatefile("${path.module}/manifests/image-warmer-daemonset.yaml", {
    name       = "image-warmer-${each.key}"
    images     = [for k, v in local.images : local.image_uris[k] if v.hardware == each.key]
    node_label = each.value
  })
  depends_on = [module.eks, null_resource.build_image]
}
