# Copy this file to terraform.tfvars and edit, then:  terraform apply
#   cp example.tfvars terraform.tfvars
# (terraform.tfvars is gitignored so your values never get committed.)
#
# ─────────────────────────────────────────────────────────────────────────────
# REQUIRED — set these for your account/reservation, or the deploy won't work.
# The trn2 ML Capacity Block is account-specific and region/AZ-scoped.
# ─────────────────────────────────────────────────────────────────────────────

# AWS region. Must be where your Capacity Block lives. Supported: us-west-2,
# us-east-2, eu-west-1.
region = "us-east-2"

# Your trn2 ML Capacity Block / EC2 Capacity Reservation ID (aws ec2
# describe-capacity-reservations). The neuron-trn2 NodePool launches into this.
trn2_capacity_reservation_id = "cr-xxxxxxxxxxxxxxxxx"

# The AZ that reservation lives in — a reservation only launches in its own AZ,
# so this must match the reservation exactly (e.g. us-east-2b).
trn2_capacity_reservation_az = "us-east-2b"

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL — defaults in variables.tf are validated. Uncomment
# and change only if you need to. Shown values are the current defaults.
# ─────────────────────────────────────────────────────────────────────────────

# name               = "demo-neuron-eks"   # EKS cluster name / resource prefix
# kubernetes_version = "1.36"

# EKS-optimized AL2023 AMI names (bump when you upgrade the cluster):
# x86_ami_name    = "amazon-eks-node-al2023-x86_64-standard-1.36-v20260903"
# neuron_ami_name = "amazon-eks-node-al2023-x86_64-neuron-1.36-v20260903"
# gpu_ami_name    = "amazon-eks-node-al2023-x86_64-nvidia-1.36-v20260903"

# Serving stack (must be a compatible vLLM-Neuron DLC + Ray with py3.13 wheels;
# Ray version must support the KubeRay operator version:
# vllm_neuron_base_image = "public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.24.0.1.1.0-neuronx-py313-sdk2.32.0-ubuntu24.04"
# ray_version            = "2.56.1"
