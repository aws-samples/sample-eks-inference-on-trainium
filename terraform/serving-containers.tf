################################################################################
# Serving images in ECR
#
# CodeBuild copies each upstream vLLM image into ECR (faster, private pulls from
# inside the VPC) and builds a Ray Serve image on top of it, for the optional
# Ray path - so Ray and standalone vLLM run the identical vLLM build:
#   <name>/vllm-neuron  copy of var.vllm_neuron_image (Neuron DLC)
#   <name>/vllm-gpu     copy of var.vllm_gpu_image (vllm-openai)
#   <name>/ray-neuron   FROM vllm-neuron + ray[serve]==var.ray_version
#   <name>/ray-gpu      FROM vllm-gpu    + ray[serve]==var.ray_version
# One build per hardware does both. vLLM copies keep the upstream tag; Ray tags
# encode both versions (ray<ver>-vllm<upstream tag>).
################################################################################

locals {
  serving_images = {
    neuron = var.vllm_neuron_image
    gpu    = var.vllm_gpu_image
  }
  vllm_image_tags = { for k, src in local.serving_images : k => split(":", src)[1] }
  ray_image_tags  = { for k, src in local.serving_images : k => "ray${var.ray_version}-vllm${split(":", src)[1]}" }
}

resource "aws_ecr_repository" "vllm" {
  for_each = local.serving_images

  name                 = "${local.name}/vllm-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_repository" "ray" {
  for_each = local.serving_images

  name                 = "${local.name}/ray-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_codebuild_project" "images" {
  name         = "${local.name}-serving-images"
  description  = "Copy the vLLM images to ECR and build the Ray Serve images on top"
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

    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
    }
    environment_variable {
      name  = "RAY_VERSION"
      value = var.ray_version
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec-serving-images.yaml")
  }
}

resource "aws_iam_role" "codebuild" {
  name = "${local.name}-serving-images-codebuild"

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
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "ecr:GetAuthorizationToken"]
        Resource = "*"
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
        Resource = concat([for r in aws_ecr_repository.vllm : r.arn], [for r in aws_ecr_repository.ray : r.arn])
      }
    ]
  })
}

# Start a build per hardware whenever its inputs change. Builds run async
# (~15-20 min); follow them in the CodeBuild console or with:
#   aws codebuild list-builds-for-project --project-name <name>-serving-images
# Rebuild: terraform -chdir=terraform apply -replace='null_resource.build_images["neuron"]'
resource "null_resource" "build_images" {
  for_each = local.serving_images

  triggers = {
    source         = each.value
    ray_tag        = local.ray_image_tags[each.key]
    buildspec_hash = filesha1("${path.module}/buildspec-serving-images.yaml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws codebuild start-build --region ${local.region} \
        --project-name ${aws_codebuild_project.images.name} \
        --environment-variables-override \
          name=SOURCE_IMAGE,value=${each.value},type=PLAINTEXT \
          name=VLLM_IMAGE,value=${aws_ecr_repository.vllm[each.key].repository_url}:${local.vllm_image_tags[each.key]},type=PLAINTEXT \
          name=RAY_IMAGE,value=${aws_ecr_repository.ray[each.key].repository_url}:${local.ray_image_tags[each.key]},type=PLAINTEXT \
        --query build.id --output text
    EOT
  }

  depends_on = [aws_iam_role_policy.codebuild]
}
