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
  name          = "ray-vllm-neuronx-build"
  description   = "Build and push Ray vLLM Docker image"
  service_role  = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                      = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                       = "LINUX_CONTAINER"
    privileged_mode            = true

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

    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
  }

  source {
    type = "NO_SOURCE"
    buildspec = "version: 0.2\n\nphases:\n  pre_build:\n    commands:\n      - echo Logging in to Amazon ECR...\n      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com\n  build:\n    commands:\n      - echo Build started on `date`\n      - echo Building the Docker image...\n      - |\n        cat > Dockerfile << 'EOF'\n        FROM public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py310-sdk2.25.0-ubuntu22.04\n        \n        USER root\n        \n        # Install Ray\n        RUN pip install ray[serve]==2.43.0\n        \n        # Create ray user and directories\n        RUN useradd -m -s /bin/bash ray && \\\n            mkdir -p /home/ray/python && \\\n            chown -R ray:ray /home/ray\n        \n        USER ray\n        WORKDIR /home/ray\n        \n        # Set environment variables\n        ENV PYTHONPATH=\"/opt/conda/lib/python3.10/site-packages:/home/ray/python:$PYTHONPATH\"\n        ENV LD_LIBRARY_PATH=\"/home/ray/anaconda3/lib:$LD_LIBRARY_PATH\"\n        \n        EXPOSE 8000 8265 10001 6379\n        \n        CMD [\"ray\", \"start\", \"--head\", \"--dashboard-host=0.0.0.0\", \"--dashboard-port=8265\"]\n        EOF\n      - docker build -t $IMAGE_REPO_NAME:$IMAGE_TAG .\n      - docker tag $IMAGE_REPO_NAME:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG\n  post_build:\n    commands:\n      - echo Build completed on `date`\n      - echo Pushing the Docker image...\n      - docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG"
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
    command = "aws codebuild start-build --project-name ${aws_codebuild_project.ray_vllm_build.name}"
  }

  depends_on = [aws_codebuild_project.ray_vllm_build]
}

# Output the ECR repository URL
output "ray_vllm_image_uri" {
  value = "${aws_ecr_repository.ray_vllm.repository_url}:latest"
}