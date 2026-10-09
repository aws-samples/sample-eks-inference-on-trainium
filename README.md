# demo-neuron-inference-eks

gpt-oss-20b inference on AWS Neuron (Trainium2) served with vLLM on Amazon EKS.
Single-instance, tensor-parallel 4, BF16 on one `trn2.3xlarge` (one Trainium2
device), with optional Ray Serve and an optional GPU (`p5.4xlarge`) deployment for
comparison. Infrastructure is provisioned with Terraform (EKS, Karpenter, S3 model
cache, observability); the model is deployed with plain Kubernetes manifests.

> **Important:** the Neuron inference stack is converging on the [vLLM Neuron plugin](https://github.com/vllm-project/vllm-neuron)
> (currently **Beta**, Trn2/Trn3-only). When adopting this solution, track the
> plugin's beta status and maturity, and confirm you can secure Trn2 capacity.
> To run a previous version of this demo based on the older vLLM+NxDI Neuron plugin 
> on Trn1 instances, switch to **branch vllm-nxdi-0.16**.

## Architecture

![Architecture](images/arch-flow.png)

### Model

- `openai/gpt-oss-20b`
- `model-weights-gpt-oss-20b` Job (created by Terraform) — downloads the model from
  HuggingFace once and uploads it to S3.
- One model directory, mirrored between S3 and each node's local NVMe:

  | S3 | Node (`/tmp/models` = NVMe) | Used as |
  |---|---|---|
  | `s3://<bucket>/<model>/` | `/tmp/models/<model>/` | `MODEL_ID` (weights) |
  | `s3://<bucket>/<model>/cache/` | `/tmp/models/<model>/cache/` | `VLLM_CACHE_ROOT` (compile cache) |
  | `s3://<bucket>/benchmarks/` | – | benchmark results |

### Serving container

- **Neuron:** the vLLM-Neuron Deep Learning Container
  (`vllm-neuronx` 0.24.0.1.1.0 / py3.13 / SDK 2.32). For Ray Serve, CodeBuild builds
  a serving image to ECR: **Ray Serve on top of the same DLC**.
- **GPU:** `vllm/vllm-openai:v0.24.0`, the same vLLM version as the Neuron DLC,
  with `--dtype bfloat16` (MoE experts stay in the checkpoint's native MXFP4).
- An init container copies the model directory from S3 to node-local NVMe (AWS CLI
  **CRT** client, accelerated parallel copy). On the first start on a node, the vLLM
  Neuron plugin compiles the model graphs (gpt-oss: 20–40 min) into `cache/` on that
  NVMe; later restarts on the same node reuse it and start in minutes. On GPU, vLLM
  builds its torch.compile cache and CUDA graphs at startup (minutes).
- `model-reader` pod SA (EKS Pod Identity) grants inference pods S3 read; the weights
  Job uses a separate `model-uploader` SA (S3 read/write).

### EKS cluster

- **Addons** — kuberay operator, vpc-cni, CoreDNS, kube-proxy, EKS Pod Identity agent, node-monitoring.
- **Managed Node Group** (AL2023 x86) — runs the cluster control plane: Karpenter
  controller, CoreDNS, AWS LB Controller, KubeRay operator, and the Prometheus/Grafana
  stack. Everything without a `karpenter` toleration lands here.
- **Karpenter node pools** (workloads only; tainted `karpenter=true`):
  - `x86-cpu-karpenter` — **static (1 node)**, hosts the weights Job, the Ray head, and CPU apps.
  - Capacity Block pools — one **static** pool per block in `capacity_blocks`
    (reserved capacity, pinned to the block's instance type + AZ), keeping all of the
    block's instances running: `neuron-trn2` (`trn2.3xlarge`) hosts the gpt-oss-20b
    deployment; optional `neuron-trn2-48xl` (`trn2.48xlarge`) and `gpu-p5-48xl`
    (`p5.48xlarge`) host the full-node deployments.
  - neuron — `trn1` and `inf2` pools for other workloads.
  - gpu — `gpu-p5` (`p5.4xlarge`, 1× H100) hosts the optional GPU deployment. Also
    `g6`, `g6e`, `g7`, `g7e`.
  - `ray-image-warmer` DaemonSet pre-pulls the Ray serving image onto every Karpenter node.

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
- A trn2 ML Capacity Block (this demo is sized for `trn2.3xlarge`)

## 1. Provision infrastructure (Terraform)

Run everything from the repository root. Terraform commands use `-chdir=terraform`
so the outputs stay reachable when you deploy in the next steps.

First, create your config from the example and set the **required** values — your
AWS region and your trn2 ML Capacity Block. These have no working defaults; without
them the trn2 node can't launch. The rest of the variables ship with validated
defaults you can keep.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform/terraform.tfvars:
#   region = "..."   # where your Capacity Block lives
#   capacity_blocks = {
#     "neuron-trn2" = {
#       reservation_id = "cr-..."        # aws ec2 describe-capacity-reservations
#       az             = "..."           # the reservation's AZ (must match)
#       instance_type  = "trn2.3xlarge"
#       node_count     = 1               # instances in the block
#       hardware       = "neuron"
#     }
#   }
```

Each `capacity_blocks` entry becomes a static Karpenter NodePool named after its key
that keeps all `node_count` instances of the block running until the block ends.
The `vllm/` manifests select pools by name, so keep the keys `neuron-trn2`,
`neuron-trn2-48xl`, and `gpu-p5-48xl`.

Then init and apply (Terraform auto-loads `terraform.tfvars`):

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

This creates the EKS cluster, Karpenter node pools, the S3 model bucket, and the
add-ons (device plugins, GPU operator/DCGM, KubeRay, monitoring). It also starts the
`model-weights-gpt-oss-20b` Job, which uploads the model weights to S3.

**Cold-start optimizations.** Two things here cut model bootstrap from
**5+ minutes to ~1 minute**:

- **Static Karpenter nodes** — the `neuron-trn2` and `x86-cpu-karpenter` pools run in
  static mode (`replicas: 1`), so a Neuron node and an x86 node are kept warm and
  ready, and the weights + compile cache stay on the Neuron node's NVMe.
- **Ray image warmer** — a DaemonSet (`ray-image-warmer`, kube-system) pre-pulls the
  multi-GB Ray + vLLM image onto every Karpenter node, so Ray head/worker pods start
  from a cached image instead of pulling it at launch.

Point `kubectl` at the new cluster and wait for the weights upload (~40 GB):

```bash
$(terraform -chdir=terraform output -raw configure_kubectl)
kubectl wait --for=condition=complete job -l app=model-weights --timeout=60m
```

Export the values the manifests need (used in the next steps):

```bash
export AWS_REGION="$(terraform -chdir=terraform output -raw region)"
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"
export CUSTOM_RAY_VLLM_IMAGE="$(terraform -chdir=terraform output -raw ray_vllm_image_uri)"
export VLLM_GPU_IMAGE="$(terraform -chdir=terraform output -raw vllm_gpu_image)"
```

## 2. Deploy the model with vLLM

Bring vLLM up by itself first — the quickest way to confirm the model, the S3 pull, and
Neuron all work, with clean single-container logs and no Ray moving parts.

```bash
envsubst '$S3_BUCKET_NAME $AWS_REGION' < vllm/vllm-gpt-oss-20b-trn2-3xl.yaml | kubectl apply -f -
```

> **First start compiles.** On a fresh node the vLLM Neuron plugin compiles the model
> before `/health` goes ready (gpt-oss: 20–40 min). The NEFFs are cached in
> `/tmp/models/gpt-oss-20b/cache/` on the node's NVMe, so later restarts on the same
> node skip it. The cache key includes the full vLLM config and the Neuron SDK version:
> keep the serve settings in the manifest unchanged (and identical to the Ray manifest)
> to reuse it.

Watch startup, then expose the vLLM endpoint locally:

```bash
kubectl logs -f deploy/gpt20b-trn2-3xl-vllm -c vllm
kubectl port-forward svc/gpt20b-trn2-3xl-vllm 8080:8080
```

In another shell, hit the OpenAI-compatible endpoint (this path runs vLLM's built-in
OpenAI server, which parses the harmony format server-side):

```bash
curl http://localhost:8080/v1/models
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "Hello"}]}' | jq
```

Before deploying Ray (§3), tear it down to free the Neuron node — the trn2.3xlarge has
a single device:

```bash
kubectl delete -f vllm/vllm-gpt-oss-20b-trn2-3xl.yaml
```

### Optional: GPU deployment for comparison

[`vllm/vllm-gpt-oss-20b-p5-4xl.yaml`](vllm/vllm-gpt-oss-20b-p5-4xl.yaml) serves the same
model with the same vLLM settings on one `p5.4xlarge` (1× H100, TP1), so benchmark
results compare like for like. It needs a region that offers `p5.4xlarge`
(e.g. us-east-1, us-east-2, us-west-2); check with
`aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=p5.4xlarge`.

```bash
envsubst '$S3_BUCKET_NAME $AWS_REGION $VLLM_GPU_IMAGE' < vllm/vllm-gpt-oss-20b-p5-4xl.yaml | kubectl apply -f -
kubectl port-forward svc/gpt20b-p5-4xl-vllm 8081:8080
```

### Optional: full-node deployments (trn2.48xlarge, p5.48xlarge)

Each runs one vLLM replica per accelerator behind one Service, using the whole node.
Both need their own Capacity Block: add a `neuron-trn2-48xl` and/or `gpu-p5-48xl`
entry to `capacity_blocks` in `terraform.tfvars` (examples are in the file) and
re-apply, which creates the matching static NodePool.

| Manifest | Node | Layout | Service |
|---|---|---|---|
| [`vllm-gpt-oss-20b-trn2-48xl.yaml`](vllm/vllm-gpt-oss-20b-trn2-48xl.yaml) | `trn2.48xlarge` | 16 × TP4 (1 device each) | `gpt20b-trn2-48xl-vllm` |
| [`vllm-gpt-oss-20b-p5-48xl.yaml`](vllm/vllm-gpt-oss-20b-p5-48xl.yaml) | `p5.48xlarge` | 8 × TP1 (1 H100 each) | `gpt20b-p5-48xl-vllm` |

```bash
envsubst '$S3_BUCKET_NAME $AWS_REGION' < vllm/vllm-gpt-oss-20b-trn2-48xl.yaml | kubectl apply -f -
envsubst '$S3_BUCKET_NAME $AWS_REGION $VLLM_GPU_IMAGE' < vllm/vllm-gpt-oss-20b-p5-48xl.yaml | kubectl apply -f -
```

The replicas share the node's NVMe: the first one pulls the model directory while the
others wait. On trn2 every replica uses the trn2.3xlarge's TP4 config, so the graphs
compile once (20–40 min) - or not at all if `cache/` already has them - and are
reused by the rest.

## 3. Optional: deploy the model on Ray Serve

Create the serving-script ConfigMap, then apply the `RayService`:

```bash
kubectl create configmap gpt-oss-20b-vllm-script --from-file=gpt_oss_20b_vllm.py=ray/gpt_oss_20b_vllm.py --dry-run=client -o yaml | kubectl apply -f -
envsubst '$CUSTOM_RAY_VLLM_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn2.yaml | kubectl apply -f -
```

Karpenter provisions the nodes (head on the x86 pool, worker on the neuron-trn2 pool),
the worker pulls the model directory from S3 to local NVMe, and Ray Serve starts the
deployment. The Ray manifest uses the same vLLM config and cache directory as §2, so
if vLLM already compiled on this node, Ray reuses the cache.

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
kubectl wait --for=condition=Ready rayservice/ray-gpt-oss-20b --timeout=2700s
kubectl port-forward svc/ray-gpt-oss-20b-serve-svc 8000:8000
```
In another shell, hit the Ray cluster endpoint with an inference request:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "Hello"}]}' | jq
```

## 4. Monitor inference metrics

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

Expose the endpoint you deployed locally — vLLM (§2) shown; for Ray (§3) use
`svc/ray-gpt-oss-20b-serve-svc 8000:8000` and port 8000 below:

```bash
kubectl port-forward svc/gpt20b-trn2-3xl-vllm 8080:8080
```

Send multiple inference requests

```bash
seq 1 100 | xargs -P 4 -I{} curl -s http://localhost:8080/v1/chat/completions \
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

The procedure is **endpoint-agnostic**: standalone vLLM (Neuron or GPU) and Ray Serve
all expose the same OpenAI-compatible API and serve the same model, so the only
thing that changes between runs is the target URL, a label, and the node price.
Run the section once against whatever you deployed; run it again with a different
`--set benchmark.target.label=` to benchmark another endpoint and compare the S3
folders (and Grafana time ranges) yourself.

### Setup

Point at the endpoint you deployed and set the node price used for the
cost/performance number:

```bash
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"

# --- pick ONE target ---
# vLLM on trn2.3xlarge (§2):
export TARGET_LABEL=gpt20b-trn2-3xl-vllm
export TARGET_URL=http://gpt20b-trn2-3xl-vllm.default.svc.cluster.local:8080
# vLLM on p5.4xlarge (§2, optional GPU):
# export TARGET_LABEL=gpt20b-p5-4xl-vllm
# export TARGET_URL=http://gpt20b-p5-4xl-vllm.default.svc.cluster.local:8080
# Full-node deployments (§2, optional):
# export TARGET_LABEL=gpt20b-trn2-48xl-vllm
# export TARGET_URL=http://gpt20b-trn2-48xl-vllm.default.svc.cluster.local:8080
# export TARGET_LABEL=gpt20b-p5-48xl-vllm
# export TARGET_URL=http://gpt20b-p5-48xl-vllm.default.svc.cluster.local:8080
# Ray Serve on trn2.3xlarge (§3):
# export TARGET_LABEL=gpt20b-trn2-3xl-ray
# export TARGET_URL=http://ray-gpt-oss-20b-serve-svc.default.svc.cluster.local:8000

# Node $/hr for cost/perf: your Capacity Block price for trn2.3xlarge, or the
# on-demand price of the GPU instance. Verify current pricing for your region.
export NODE_HOURLY_USD=<price>
```

Confirm the endpoint is reachable from inside the cluster:

```bash
kubectl run curl-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s "$TARGET_URL/v1/models"
```

### Run

One install creates a single Job that runs the tests **sequentially** in one pod
(latency → throughput), so the latency numbers are measured under zero
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
Results land in S3 under `benchmarks/<label>/<test>/`: the client-side report
(`summary_lifecycle_metrics.json`, per-stage files) plus the **server-side** vLLM
metrics for the same window, which inference-perf queries from Prometheus (filtered
to the target's Service, so other endpoints don't mix in). For a Ray target, add
`--set benchmark.metrics.prometheus.enabled=false` (Ray Serve exports vLLM metrics
differently).

### Visualize

**Client-side metrics** — [`benchmark/visualize.py`](benchmark/visualize.py) pulls
the latest latency and throughput summaries from S3 and prints the answers:

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
- **GPU / DCGM** — GPU utilization and memory on the p5 node (GPU target only)

The client-side table tells you *what* the endpoint delivers; the hardware/vLLM
dashboards tell you *why* it saturates where it does.

### Reference results

Measured on an earlier configuration of this demo — standalone vLLM on one
`trn2.48xlarge` with tensor-parallel 8 (`label=vllm`). Results for the current
`trn2.3xlarge` / TP4 configuration will differ.

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


## 6. Teardown

Delete the workloads and Karpenter node pools **first** so Karpenter (still running)
terminates the nodes it launched, then let Terraform remove the rest. Otherwise those
instances orphan and block VPC/subnet/SG deletion.

```bash
# 1. Delete the serving workloads.
helm uninstall "$TARGET_LABEL" -n default 2>/dev/null || true
kubectl delete -f vllm/vllm-gpt-oss-20b-trn2-3xl.yaml 2>/dev/null || true
kubectl delete -f vllm/vllm-gpt-oss-20b-p5-4xl.yaml 2>/dev/null || true
kubectl delete -f vllm/vllm-gpt-oss-20b-trn2-48xl.yaml 2>/dev/null || true
kubectl delete -f vllm/vllm-gpt-oss-20b-p5-48xl.yaml 2>/dev/null || true
kubectl delete rayservice ray-gpt-oss-20b 2>/dev/null || true

# 2. Delete the Karpenter node pools (+ node classes / claims) so Karpenter
#    terminates every instance it launched — static pools included.
kubectl delete nodepools --all
kubectl delete ec2nodeclasses --all
kubectl delete nodeclaims --all      # catch any stragglers

# 3. Wait until all non-MNG nodes are gone. Karpenter nodes carry the
#    karpenter.sh/nodepool label; the managed node group nodes do not. Proceed
#    only when this prints "No resources found" (instances have terminated).
kubectl get nodes -l karpenter.sh/nodepool -w    # Ctrl-C once empty

# 4. Now destroy — no orphaned Karpenter instances left to block the VPC.
terraform -chdir=terraform destroy
```

> **This is irreversible.** `terraform destroy` deletes the EKS cluster, the
> Karpenter nodes, the observability stack, and the S3 model bucket
> (weights + compile cache + benchmark results). Back up anything you want to keep
> from S3 first. Review the plan before confirming.
