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
- runs the `model-compile-s3` Job (on trn1): it downloads upstream Mistral-7B-v0.3,
  runs one offline vLLM inference to compile the model (NxDI writes the full compiled
  artifacts — NEFFs, sharded weights, metadata), and uploads that directory to
  `s3://<bucket>/mistral-7b-v0.3`. Serving pulls it and sets `NEURON_COMPILED_ARTIFACTS`,
  so model load skips compilation. The vLLM config is shared via env vars across the
  compile job and both serving paths so the artifacts always match.

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

kubectl logs -f deploy/vllm-mistral7b -c vllm         # watch model pull + Neuron startup
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
kubectl create configmap mistral7b-vllm-script --from-file=mistral7b_vllm.py=ray/mistral7b_vllm.py
envsubst '$CUSTOM_RAY_VLLM_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn1.yaml | kubectl apply -f -
```

Karpenter provisions the nodes (head on the x86 pool, worker on the neuron-trn1 pool),
the worker pulls the model from S3 to local NVMe, and Ray Serve starts the deployment.

Watch progress on the Ray dashboard (port 8265 on the head):

```bash
kubectl port-forward svc/ray-mistral7b-head-svc 8265:8265
# open http://localhost:8265  (Serve tab shows the mistral7b-vllm app status)
```

Test it:

```bash
kubectl get rayservice ray-mistral7b
kubectl port-forward svc/ray-mistral7b-serve-svc 8000:8000

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
kubectl get grafanadashboard -n monitoring          # neuron, gpu-dcgm, ray-*, vllm
kubectl get daemonset neuron-monitor -n monitoring  # 1 pod per Neuron node
```

Confirm Neuron metrics are flowing:

```bash
NM=$(kubectl get pods -l app=neuron-monitor -n monitoring -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring "$NM" 9010:9010
curl -s http://127.0.0.1:9010/metrics | grep -i neuron | head
```

### Access Grafana

Grafana runs internally (ClusterIP). For quick local access:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:3000
# open http://localhost:3000
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
# user: admin
```

Dashboards land under the `monitoring` folder: **Neuron-Monitor**, **GPU / DCGM**,
Ray **Default / Serve / Serve Deployment**, and **vLLM**. Generate traffic (curl the
chat endpoint) and set the time range to the last 15 minutes if a panel looks empty.

> To expose Grafana publicly instead, create an ALB Ingress for
> `kube-prometheus-stack-grafana:3000` and restrict `alb.ingress.kubernetes.io/inbound-cidrs`
> to your IP (`curl https://checkip.amazonaws.com`). It's left out of Terraform on
> purpose — an internet-facing Grafana is a deliberate, security-sensitive choice.
