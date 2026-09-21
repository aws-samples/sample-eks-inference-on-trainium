# demo-neuron-inference-eks

Mistral-7B inference on AWS Neuron (Trainium/Inferentia) served with vLLM + Ray Serve
on Amazon EKS. Infrastructure is provisioned with Terraform (EKS, Karpenter, S3 model
cache, observability); the model is served as a `RayService`.

## Prerequisites

- Terraform, `kubectl`, `awscli` v2, `helm`, and `envsubst` (from `gettext`)
- AWS credentials for the target account/region

## 1. Provision infrastructure (Terraform)

Run everything from the repository root. Terraform commands use `-chdir=terraform`
so the outputs stay reachable when you deploy Ray in the next step.

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

This creates the EKS cluster, Karpenter node pools, the S3 model cache, and the
add-ons (device plugins, GPU operator/DCGM, KubeRay, monitoring). The apply also:

- builds and pushes the custom Ray + vLLM image via CodeBuild, and
- runs the `model-download-s3` Job that downloads the model and uploads it to S3.

Point `kubectl` at the new cluster and wait for the model cache to finish:

```bash
aws eks update-kubeconfig --region us-east-2 --name demo-neuron-eks
kubectl wait --for=condition=complete job/model-download-s3 --timeout=30m
```

## 2. Deploy the model (Ray)

Export the values the manifest needs (pulled from Terraform outputs), create the
serving-script ConfigMap, then apply the `RayService`:

```bash
export AWS_REGION="us-east-2"
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"
export CUSTOM_RAY_VLLM_IMAGE="$(terraform -chdir=terraform output -raw ray_vllm_image_uri)"

kubectl create configmap mistral-7b-vllm-script --from-file=mistral_7b_vllm.py=ray/mistral_7b_vllm.py

# Substitute only these vars; leave $PYTHONPATH/$LD_LIBRARY_PATH literal.
envsubst '$CUSTOM_RAY_VLLM_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn1.yaml \
  | kubectl apply -f -
```

Karpenter provisions a Neuron node, the worker pulls the model from S3 to local NVMe,
and Ray Serve starts the deployment.

## 3. Test

```bash
kubectl get rayservice mistral-7b-vllm
kubectl port-forward svc/mistral-7b-vllm-serve-svc 8000:8000

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/mistral-7b-v0.3", "messages": [{"role": "user", "content": "Hello"}]}'
```
