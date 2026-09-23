# demo-neuron-inference-eks

Mistral-7B inference on AWS Neuron (Trainium/Inferentia) served with vLLM + Ray Serve
on Amazon EKS. Infrastructure is provisioned with Terraform (EKS, Karpenter, S3 model
cache, observability); the model is served as a `RayService`.

## Architecture

![Architecture](images/arch-flow.png)

### Model

- `mistral-7b-v0.3`
- `model-compile-s3` Job — downloads the upstream model from HuggingFace, compiles it
  to Neuron NEFFs (offline vLLM/NxDI), and pushes the compiled artifacts to S3.

### Serving container

- CodeBuild builds the serving image to ECR: **Ray Serve + vLLM (NxDI) on the Neuron
  Deep Learning Container** (`vllm-neuronx` 0.16 / SDK 2.31).
- Init container copies the model from S3 to node-local NVMe (AWS CLI **CRT** client,
  accelerated parallel copy).
- `model-reader` pod SA (EKS Pod Identity) grants inference pods S3 read; the compile
  Job uses a separate `model-uploader` SA (read/write).

### EKS cluster

- **Addons** — vpc-cni, CoreDNS, kube-proxy, EKS Pod Identity agent, node-monitoring.
- **Managed Node Group** (AL2023 x86) — runs the cluster control plane: Karpenter
  controller, CoreDNS, AWS LB Controller, KubeRay operator, and the Prometheus/Grafana
  stack. Everything without a `karpenter` toleration lands here.
- **Karpenter node pools** (workloads only; tainted `karpenter=true`):
  - `x86-cpu-karpenter` — **static (1 node)**, hosts the Ray head + CPU apps.
  - neuron — `trn1` **static (1 node)**, `trn2` (ML Capacity Block / reserved), `inf2`.
  - gpu — `g6`, `g6e`, `g7`, `g7e`.
  - `ray-image-warmer` DaemonSet pre-pulls the serving image onto every Karpenter node.

### Expose inference endpoint

- AWS Load Balancer Controller exposes the Ray Serve endpoint via a K8s Ingress (ALB).

### Observability

- kube-prometheus-stack + Grafana (dashboards via grafana-operator).
- neuron-monitor — Trainium/Inferentia hardware metrics.
- NVIDIA DCGM exporter — GPU metrics.
- Ray head/worker PodMonitors — Ray + Ray Serve (vLLM) metrics.

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

**Cold-start optimizations.** Two things here cut Ray cluster + model bootstrap from
**5+ minutes to ~1 minute**:

- **Static Karpenter nodes** — the `neuron-trn1` and `x86-cpu-karpenter` pools run in
  static mode (`replicas: 1`), so a Neuron worker node and an x86 Ray head node are kept
  warm and ready.
- **Ray image warmer** — a DaemonSet (`ray-image-warmer`, kube-system) pre-pulls the
  multi-GB Ray + vLLM image onto every Karpenter node, so Ray head/worker pods start
  from a cached image instead of pulling it at launch.

**Note**: The vLLM config (model, tensor-parallel size, max sequence length, max
num seqs, dtype) **must match** between the compile job and the serving containers,
or the compiled artifacts won't be reused and the model recompiles at serve time. 
The same config it's defined via env vars across the compile job and both serving paths (vLLM, Ray).

Point `kubectl` at the new cluster and wait for the compile job (it can take a while):

```bash
aws eks update-kubeconfig --region us-east-2 --name demo-neuron-eks
kubectl wait --for=condition=complete job/model-compile-s3 --timeout=60m
```

Export the values the manifests need (used in the next two steps):

```bash
export AWS_REGION="us-east-2"
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"
export CUSTOM_RAY_VLLM_IMAGE="$(terraform -chdir=terraform output -raw ray_vllm_image_uri)"
```

## 2. Validate inference with standalone vLLM (no Ray)

Bring vLLM up by itself first — the quickest way to confirm the model, the S3 pull, and
Neuron all work, with clean single-container logs and no Ray moving parts.

```bash
envsubst '$S3_BUCKET_NAME $AWS_REGION' < vllm/mistral-vllm-deployment.yaml | kubectl apply -f -
```

Expose the vLLM endpoint locally (optionally watch startup first with
`kubectl logs -f deploy/vllm-mistral7b -c vllm`):

```bash
kubectl port-forward svc/vllm-mistral7b 8080:8080
```

In another shell, hit the OpenAI-compatible endpoint:

```bash
curl http://localhost:8080/v1/models
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/mistral-7b-v0.3", "messages": [{"role": "user", "content": "Hello"}]}' | jq
```

Once inference works, tear it down before deploying Ray (frees the Neuron node):

```bash
kubectl delete -f vllm/mistral-vllm-deployment.yaml
```

## 3. Deploy the model on Ray Serve

Create the serving-script ConfigMap, then apply the `RayService`:

```bash
kubectl create configmap mistral7b-vllm-script --from-file=mistral7b_vllm.py=ray/mistral7b_vllm.py --dry-run=client -o yaml | kubectl apply -f -
envsubst '$CUSTOM_RAY_VLLM_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn1.yaml | kubectl apply -f -
```

Karpenter provisions the nodes (head on the x86 pool, worker on the neuron-trn1 pool),
the worker pulls the model from S3 to local NVMe, and Ray Serve starts the deployment.

Watch progress on the Ray dashboard (port 8265 on the head):

```bash
kubectl port-forward svc/ray-mistral7b-head-svc 8265:8265
```

Open http://localhost:8265 to visualize the Ray dashboard.

Expose Ray cluster endpoint locally:

```bash
kubectl wait --for=condition=Ready rayservice/ray-mistral7b --timeout=1200s
kubectl port-forward svc/ray-mistral7b-serve-svc 8000:8000
```
In another shell, hit the Ray cluster endpoint with an inference request:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/mistral-7b-v0.3", "messages": [{"role": "user", "content": "Hello"}]}' | jq
```

## 4. Observability

The observability stack is provisioned by Terraform (§1) — you don't deploy it by
hand. In the `monitoring` namespace you get:

- **kube-prometheus-stack** — Prometheus, Alertmanager, node-exporter, kube-state-metrics
- **grafana-operator** + an `external-grafana` instance, with dashboards loaded from
  every JSON under `terraform/grafana-dashboards/` (one ConfigMap + `GrafanaDashboard`
  CR each)
- **neuron-monitor** DaemonSet + ServiceMonitor — Trainium/Inferentia HW metrics on :9010
- **NVIDIA DCGM exporter** (via the GPU operator) — GPU metrics
- **Ray head/worker PodMonitors** — Ray, autoscaler, and Ray Serve (vLLM-on-Ray) metrics

### Verify the stack

```bash
kubectl get pods -n monitoring
kubectl get servicemonitor,podmonitor -n monitoring
kubectl get grafanadashboard -n monitoring
kubectl get daemonset neuron-monitor -n monitoring
```

### Confirm Neuron metrics are flowing:

Expose Neuron Monitor locally:
```bash
NM=$(kubectl get pods -l app=neuron-monitor -n monitoring -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring "$NM" 9010:9010
```
Query Neuon metrics
```bash
curl -s http://127.0.0.1:9010/metrics | grep -i neuron | head
```

### Access Grafana

Retrive Grafana credentials:
- **User**: admin
- **Password**:
```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

Expose Grafana endpoint locally

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:3000
```

Open http://localhost:3000

Dashboards land under the `monitoring` folder: **Neuron-Monitor**, **GPU / DCGM**,
Ray **Default / Serve / Serve Deployment**, and **vLLM**. Generate traffic (curl the
chat endpoint) and set the time range to the last 15 minutes if a panel looks empty.

> To expose Grafana publicly instead, create an ALB Ingress for
> `kube-prometheus-stack-grafana:3000` and restrict `alb.ingress.kubernetes.io/inbound-cidrs`
> to your IP (`curl https://checkip.amazonaws.com`). It's left out of Terraform on
> purpose — an internet-facing Grafana is a deliberate, security-sensitive choice.

### Generate traffic load

Expose Ray cluster endpoint locally:

```bash
kubectl port-forward svc/ray-mistral7b-serve-svc 8000:8000
```

Send multiple inference requests

```bash
seq 1 100 | xargs -P 4 -I{} curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"/tmp/models/mistral-7b-v0.3","messages":[{"role":"user","content":"Hello"}]}' -o /dev/null
```