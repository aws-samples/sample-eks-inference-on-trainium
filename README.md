# demo-neuron-inference-eks

gpt-oss-20b inference on AWS Neuron (Trainium2) served with vLLM + Ray Serve on
Amazon EKS. Single-instance, tensor-parallel 8, BF16 on one `trn2.48xlarge`.
Infrastructure is provisioned with Terraform (EKS, Karpenter, S3 model cache,
observability); the model is served as a `RayService`.

> **Maturity note (be honest for regulated deployments):** this rides the
> **standalone vLLM Neuron plugin (0.24, Beta)**, Trn2/Trn3-only. On Trn2 the model
> runs in **BF16** (the efficient MXFP4 path is Trn3-only). gpt-oss has known Neuron
> enablement friction — cold compile is **20–40 min** — so budget enablement and
> accuracy-validation effort. `trn2.48xlarge` is scarce, GTM-gated capacity; use
> Capacity Blocks for ML rather than blind on-demand.

## Architecture

![Architecture](images/arch-flow.png)

### Model

- `openai/gpt-oss-20b`
- `model-compile-s3` Job — downloads the upstream model from HuggingFace, compiles it
  to Neuron NEFFs by launching the exact `vllm serve` command (the plugin compiles on
  first launch, before `/health` goes ready), and pushes the weights + NEFF cache
  (`VLLM_CACHE_ROOT`) to S3.

### Serving container

- CodeBuild builds the serving image to ECR: **Ray Serve + the standalone vLLM Neuron
  plugin on the Neuron Deep Learning Container**
  (`vllm-neuronx` 0.24.0.1.1.0 / py3.13 / SDK 2.32).
- Init container copies the model + NEFF cache from S3 to node-local NVMe (AWS CLI
  **CRT** client, accelerated parallel copy), so serving skips recompilation.
- `model-reader` pod SA (EKS Pod Identity) grants inference pods S3 read; the compile
  Job uses a separate `model-uploader` SA (read/write).

### EKS cluster

- **Addons** — vpc-cni, CoreDNS, kube-proxy, EKS Pod Identity agent, node-monitoring.
- **Managed Node Group** (AL2023 x86) — runs the cluster control plane: Karpenter
  controller, CoreDNS, AWS LB Controller, KubeRay operator, and the Prometheus/Grafana
  stack. Everything without a `karpenter` toleration lands here.
- **Karpenter node pools** (workloads only; tainted `karpenter=true`):
  - `x86-cpu-karpenter` — **static (1 node)**, hosts the Ray head + CPU apps.
  - neuron — `trn2` **static (1 node)**, on an ML Capacity Block (reserved), hosts the
    gpt-oss-20b worker. Also `trn1` and `inf2` pools for other workloads.
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

- **Static Karpenter nodes** — the `neuron-trn2` and `x86-cpu-karpenter` pools run in
  static mode (`replicas: 1`), so a Neuron worker node and an x86 Ray head node are kept
  warm and ready.
- **Ray image warmer** — a DaemonSet (`ray-image-warmer`, kube-system) pre-pulls the
  multi-GB Ray + vLLM image onto every Karpenter node, so Ray head/worker pods start
  from a cached image instead of pulling it at launch.

**Note**: The vLLM config (model, tensor-parallel size, max sequence length, max num
seqs, max num batched tokens, and the `--hf-overrides` / `--additional-config` JSON
blobs) **must match** between the compile job and the serving containers, or the
NEFF cache won't be reused and the model recompiles at serve time (20–40 min). The
scalar knobs are env vars across the compile job and both serving paths (vLLM, Ray);
the two JSON flags are inlined identically in each manifest.

Point `kubectl` at the new cluster and wait for the compile job (it can take a while):

```bash
aws eks update-kubeconfig --region us-east-2 --name demo-neuron-eks
kubectl wait --for=condition=complete job/model-compile-s3 --timeout=80m
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
envsubst '$S3_BUCKET_NAME $AWS_REGION' < vllm/gpt-oss-vllm-deployment.yaml | kubectl apply -f -
```

Expose the vLLM endpoint locally (optionally watch startup first with
`kubectl logs -f deploy/vllm-gpt-oss-20b -c vllm`):

```bash
kubectl port-forward svc/vllm-gpt-oss-20b 8080:8080
```

In another shell, hit the OpenAI-compatible endpoint (this path runs vLLM's built-in
OpenAI server, which parses the harmony format server-side):

```bash
curl http://localhost:8080/v1/models
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "Hello"}]}' | jq
```

Once inference works, tear it down before deploying Ray (frees the Neuron node):

```bash
kubectl delete -f vllm/gpt-oss-vllm-deployment.yaml
```

## 3. Deploy the model on Ray Serve

Create the serving-script ConfigMap, then apply the `RayService`:

```bash
kubectl create configmap gpt-oss-20b-vllm-script --from-file=gpt_oss_20b_vllm.py=ray/gpt_oss_20b_vllm.py --dry-run=client -o yaml | kubectl apply -f -
envsubst '$CUSTOM_RAY_VLLM_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn2.yaml | kubectl apply -f -
```

Karpenter provisions the nodes (head on the x86 pool, worker on the neuron-trn2 pool),
the worker pulls the model from S3 to local NVMe, and Ray Serve starts the deployment.

Watch progress on the Ray dashboard (port 8265 on the head). The head service
carries a per-cluster hash suffix, so select it by label instead of guessing the
name — the head pod (and dashboard) come up well before the workers or Serve:

```bash
RAY_HEAD_SVC=$(kubectl get svc -l ray.io/node-type=head -o name)
kubectl port-forward "$RAY_HEAD_SVC" 8265:8265
```

Open http://localhost:8265 to visualize the Ray dashboard.

Expose Ray cluster endpoint locally:

```bash
kubectl wait --for=condition=Ready rayservice/ray-gpt-oss-20b --timeout=1200s
kubectl port-forward svc/ray-gpt-oss-20b-serve-svc 8000:8000
```
In another shell, hit the Ray cluster endpoint with an inference request:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "Hello"}]}' | jq
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
kubectl port-forward svc/ray-gpt-oss-20b-serve-svc 8000:8000
```

Send multiple inference requests

```bash
seq 1 100 | xargs -P 4 -I{} curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"/tmp/models/gpt-oss-20b","messages":[{"role":"user","content":"Hello"}]}' -o /dev/null
```

## 5. Benchmark inference performance

Measure how the deployment actually performs under load with
[inference-perf](https://github.com/kubernetes-sigs/inference-perf), a
model-server-agnostic load generator that runs as a Kubernetes Job and writes
results to S3. The [`benchmark/`](benchmark/) Helm chart packages it into
tests that each answer one question:

Both tests use the **same real ShareGPT chat workload** (natural prompt lengths,
generation stops at EOS) and differ only in load, so the numbers form one
coherent story for a chat app:

| Test | Question | Load |
|---|---|---|
| **chat-latency** | Best-case p50/p95 latency? | 1 req/s, single-request floor |
| **chat-throughput** | Highest sustained output tokens/sec? | rates ramped (1→2→4 req/s) into saturation |
| **cost/performance** | Best tokens per dollar? | *derived* — throughput peak ÷ node $/hr |

inference-perf auto-downloads the ShareGPT dataset from HuggingFace at job start,
so the benchmark pod needs outbound internet (same as the tokenizer download). To
benchmark a different corpus (e.g. UltraChat), convert it to the ShareGPT JSON
schema, mount it, and set the test's `data.path`.

The procedure is **endpoint-agnostic**: because standalone vLLM and Ray Serve
both expose the same OpenAI-compatible API and serve the same model, the only
thing that changes between runs is the target URL and a label. Run the section
once against whatever you deployed; run it again with a different `--set
benchmark.target.label=` to benchmark another endpoint and compare the two S3
folders (and Grafana time ranges) yourself.

### Setup

Point at the endpoint you deployed (§2 vLLM or §3 Ray) and set the node price
used for the cost/performance number:

```bash
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"

# --- pick ONE target ---
# Standalone vLLM (§2):
export TARGET_LABEL=vllm
export TARGET_URL=http://vllm-gpt-oss-20b.default.svc.cluster.local:8080
# Ray Serve (§3):
# export TARGET_LABEL=ray
# export TARGET_URL=http://ray-gpt-oss-20b-serve-svc.default.svc.cluster.local:8000

# Node on-demand price for cost/perf (default assumes one trn2.48xlarge).
export NODE_HOURLY_USD=35.0
```

Confirm the endpoint is reachable from inside the cluster and inspect the chart
defaults:

```bash
kubectl run curl-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s "$TARGET_URL/v1/models"
```

### Run

One install creates a single Job that runs the tests **sequentially** in one pod
(latency → throughput → chat), so the latency numbers are measured under zero
competing load before the sweeps saturate the endpoint:

```bash
helm install "$TARGET_LABEL" benchmark/ \
  -n default \
  --set benchmark.storage.s3.bucketName="$S3_BUCKET_NAME" \
  --set benchmark.target.label="$TARGET_LABEL" \
  --set benchmark.target.baseUrl="$TARGET_URL" \
  --set benchmark.cost.hourlyUsd="$NODE_HOURLY_USD"
```

Or edit `benchmark/values.yaml` for additional test configuration (enable/disable
tests, change `runOrder`, tune sweep sizes).

Wait for the Job to finish (all tests run in sequence, so this takes a few min):

```bash
kubectl wait --for=condition=complete job \
  -l benchmark.target="$TARGET_LABEL" -n default --timeout=900s
```

Follow progress with `kubectl logs -n default -l benchmark.target=$TARGET_LABEL -f`.
Results land in S3 under `benchmarks/<label>/<test>/`.

### Visualize

**Client-side metrics** — [`benchmark/visualize.py`](benchmark/visualize.py) pulls
the latest latency, throughput, and chat summaries from S3 and prints the answers:

```bash
benchmark/visualize.py \
  --bucket "$S3_BUCKET_NAME" \
  --label "$TARGET_LABEL" \
  --hourly-usd "$NODE_HOURLY_USD"
```

**Engine + hardware metrics** — while the throughput Job runs (or set the
Grafana time range to the last 15 min afterward), open the dashboards from §4
that match your target to see *why* the numbers look the way they do:

- **vLLM** — request queue time, KV-cache utilization, scheduler state
- **Ray Serve** — replica load and queueing (Ray target only)
- **Neuron-Monitor** — NeuronCore utilization and HW throughput on the trn2 node

The client-side table tells you *what* the endpoint delivers; the Neuron/vLLM
dashboards tell you *why* it saturates where it does.

### Reference results

Measured on the standalone vLLM endpoint (`label=vllm`).

**Measured configuration**

| Parameter | Value |
|---|---|
| Model | `openai/gpt-oss-20b` (BF16) |
| Hardware | 1× `trn2.48xlarge`, tensor-parallel 8 |
| Context window (`max_model_len`) | 16384 |
| Max batched tokens (`max_num_batched_tokens`) | 8192 |
| Max batch (`max_num_seqs`) | 4 |
| Prefix caching / segmented prefill | enabled |
| Workload / dataset | **ShareGPT** — real chat prompts, natural input/output lengths, generation stops at EOS (auto-downloaded from HuggingFace) |
| API | OpenAI `completion`, streaming |
| Load — latency test | constant 1 req/s, 30 s, 4 workers |
| Load — throughput test | constant, ramped 1 → 2 → 4 req/s, 30 s per stage, 8 workers |

**Results** (0% errors; latency rows from the 1 rps zero-contention test, throughput from the ramped test's peak stage)

| Metric | Median | p90 | Mean |
|---|---|---|---|
| TTFT — time to first token (ms) | 481 | 1,550 | 842 |
| ITL — inter-token latency (ms) | 11.6 | 11.7 | 16.5 |
| TPOT — time per output token (ms) | 15.5 | 26.8 | 31.9 |
| Request latency (s) | 2.87 | 9.79 | 3.79 |
| Output throughput (tokens/s) | — | — | 217.8 (peak) |
| Request throughput (req/s) | — | — | 1.0 (peak) |

### Remove the benchmark run

```bash
helm uninstall "$TARGET_LABEL" -n default
```

To benchmark another endpoint, deploy it (§2/§3), re-export `TARGET_LABEL` +
`TARGET_URL` (and `NODE_HOURLY_USD` if the instance differs), and repeat.
Results accumulate under separate `benchmarks/<label>/` prefixes for
side-by-side comparison.

## 6. Teardown

Tear the whole demo down with Terraform. First remove the serving workloads so
Karpenter releases the (expensive, capacity-blocked) trn2 node, then destroy the
infrastructure:

```bash
# Delete serving workloads (ignore errors if already gone)
helm uninstall "$TARGET_LABEL" -n default 2>/dev/null || true
kubectl delete -f vllm/gpt-oss-vllm-deployment.yaml 2>/dev/null || true
kubectl delete rayservice ray-gpt-oss-20b 2>/dev/null || true

# Destroy all infrastructure (EKS cluster, Karpenter nodes, S3 bucket, add-ons)
terraform -chdir=terraform destroy
```

> **This is irreversible.** `terraform destroy` deletes the EKS cluster, the
> Karpenter nodes, the observability stack, and the S3 model-cache bucket
> (weights + NEFF cache + benchmark results). Back up anything you want to keep
> from S3 first. Review the plan before confirming.




