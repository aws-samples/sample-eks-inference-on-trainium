# ECR Repository for custom Ray vLLM image
resource "aws_ecr_repository" "ray_vllm" {
  name                 = "ray-vllm-neuronx"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# CodeBuild project to build and push Docker image
resource "aws_codebuild_project" "ray_vllm_build" {
  name         = "ray-vllm-neuronx-build"
  description  = "Build and push Ray vLLM Docker image"
  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.ray_vllm.name
    }

    # Versions are the single source of truth (locals). The buildspec consumes
    # BASE_IMAGE (FROM) and RAY_VERSION (pip install); IMAGE_TAG encodes both.
    environment_variable {
      name  = "BASE_IMAGE"
      value = var.vllm_neuron_base_image
    }

    environment_variable {
      name  = "RAY_VERSION"
      value = var.ray_version
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = local.ray_vllm_image_tag
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec-inference-container.yaml")
  }
}

# IAM role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "ray-vllm-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# Trigger CodeBuild to run during deployment
resource "null_resource" "build_image" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "aws codebuild start-build --project-name ${aws_codebuild_project.ray_vllm_build.name} --region ${local.region}"
  }

  depends_on = [aws_codebuild_project.ray_vllm_build]
}
