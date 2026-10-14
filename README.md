# Deploy and Benchmark GPT-OSS on Trainium and GPU

A production-ready architecture on Amazon EKS that runs OpenAI's open-weight
**gpt-oss-20b** on both AWS Trainium (`trn2.48xlarge`) and NVIDIA GPU
(`p5.48xlarge`), and a pipeline that takes you from a model to measured
inference endpoints on either one: Terraform for the compute, model cache and
serving containers, and Helm for the Neuron compilation, the vLLM endpoints and
the benchmark.

Nothing is hidden or abstracted. You build the stack step by step, so you understand
every moving part, and can automate it, or point it at another model or
accelerator, once you know the steps:

1. **Infrastructure:** VPC, EKS, Karpenter node pools from your Capacity Blocks,
   an S3 model cache, and the serving containers in ECR.
2. **Serving inference:** compile the model ahead of time for Neuron, then
   deploy vLLM endpoints on Trainium and GPU.
3. **Observability:** Neuron, GPU and vLLM metrics in Prometheus and Grafana.
4. **Benchmark:** latency, throughput and cost tests against both endpoints at
   once, with results in S3.

> **Important:** the Neuron inference stack is converging on the [vLLM Neuron plugin](https://github.com/vllm-project/vllm-neuron)
> (currently **Beta**, Trn2/Trn3 only). When adopting this solution, track the
> plugin's beta status and maturity, and confirm you can secure Trn2 capacity.
> To run a previous version of this demo based on the older vLLM+NxDI Neuron plugin
> on Trn1 instances, switch to **branch vllm-nxdi-0.16**.

![Architecture](images/arch-flow.png)

**Prerequisites:** Terraform, `kubectl`, `helm`, AWS CLI v2, and AWS credentials
for the target account.

## Section 1: Infrastructure

### 1. Define model, hardware and inference engine

Define the target model, hardware, and serving engine. 

| | AWS Trainium | NVIDIA GPU |
|---|---|---|
| Model (HuggingFace) | `openai/gpt-oss-20b` | `openai/gpt-oss-20b` |
| Instance | `trn2.48xlarge` | `p5.48xlarge` |
| Accelerators | 16 Trainium2 devices (64 logical NeuronCores) - 1,536 GiB HBM3 | 8 NVIDIA H100 - 80 GB |
| Node pool | `neuron-trn2-48xl` | `gpu-p5-48xl` |
| Inference engine | vLLM 0.24 + vLLM Neuron plugin (SDK 2.32) | vLLM 0.24 |
| Serving container | `public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.24.0.1.1.0-neuronx-py313-sdk2.32.0-ubuntu24.04` | `vllm/vllm-openai:v0.24.0` |


**Weights and precision:** both use the same GPT-OSS-20B checkpoint. Its MoE expert weights are MXFP4; everything else (attention, embeddings, router) is BF16.

- **GPU (advantage):** vLLM keeps the expert weights in MXFP4 and only expands them inside the MoE kernel, so the 4-bit weights stay compressed in HBM. gpt-oss-20b occupies a smaller footprint and the engine reads about 4x fewer expert-weight bytes per token, which is decisive on bandwidth-bound decode.
- **Neuron (gap, then the fix):** Trainium2 has no sub-8-bit datapath, so the MXFP4 experts are dequantized to BF16 at load time. The model computes in BF16 and loses the 4-bit memory and bandwidth advantage. Trainium3 removes this gap: it supports MXFP4 natively, keeping the experts compressed and computed at 4-bit like the GPU.

### 2. Reserve compute capacity

Use [EC2 Capacity Blocks for ML](https://aws.amazon.com/ec2/capacityblocks/) to reserve `trn2` and `p5` capacity for days to weeks, which suits testing and benchmarking.
Reserve one block per instance type, in the same region.

Check which AZs offer the instance types:

```bash
export AWS_REGION=us-east-2
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=trn2.48xlarge,p5.48xlarge --output table
```

Once your blocks are reserved, note each one's ID, instance type, AZ and
instance count. You need them in step 3:

```bash
aws ec2 describe-capacity-reservations --filters Name=state,Values=active,scheduled \
  --query 'CapacityReservations[].[CapacityReservationId,InstanceType,AvailabilityZone,TotalInstanceCount,StartDate,EndDate]' --output table
```

### 3. Apply Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`: set the region and add one `capacity_blocks_nodepools`
entry per block from step 2, keyed by its node pool name from you definitions:

Example:
```hcl
region = "us-east-2"

capacity_blocks_nodepools = {
  "neuron-trn2-48xl" = {
    reservation_id = "cr-..."
    instance_type  = "trn2.48xlarge"
    az             = "us-east-2b"
    node_count     = 1
    hardware       = "neuron"
  }
  "gpu-p5-48xl" = {
    reservation_id = "cr-..."
    instance_type  = "p5.48xlarge"
    az             = "us-east-2a"
    node_count     = 1
    hardware       = "gpu"
  }
}
```

The other inputs use default values. Override them in `terraform.tfvars`
if your definitions differ (see [`variables.tf`](terraform/variables.tf)):

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

#### What Terraform deploys

**VPC Networking** ([`vpc.tf`](terraform/vpc.tf))

- A VPC with public and private subnets across the region's AZs, and a NAT
  gateway. Nodes run in the private subnets.

**Compute**

- **EKS cluster and add-ons** ([`eks.tf`](terraform/eks.tf), [`addons.tf`](terraform/addons.tf)):
  a managed node group runs every controller (Karpenter, CoreDNS, AWS Load
  Balancer Controller, KubeRay, GPU operator, Prometheus/Grafana), pinned with
  `nodeSelector: karpenter.sh/controller=true`. Node agents run as DaemonSets that
  tolerate every taint, so they also run on the accelerator nodes: the Neuron
  device plugin and neuron-monitor, the NVIDIA device plugin and DCGM exporter,
  and node-exporter.
- **Karpenter node pools** ([`karpenter.tf`](terraform/karpenter.tf), [`karpenter/`](terraform/karpenter/)):
  - **Default Nodepool:** `x86-cpu-karpenter`, On-Demand c5/m5/r5 nodes for CPU
    work (model cache Job, the Ray head). A node launches when a pod
    needs one and is removed when empty.
  - **Generated from `capacity_blocks_nodepools`:** one static pool per entry
    ([template](terraform/karpenter/capacity-block-nodepool.yaml.tftpl)), pinned
    to the block's instance type and AZ on reserved capacity. It keeps the
    block's instances running until the block ends.
  - Accelerator pools are tainted, so only pods that tolerate the taint land
    there. Their NVMe instance store is mounted at `/mnt/k8s-disks/0`.
- **Accelerated AMIs:** three EC2NodeClasses, one per AMI input:
  `x86-cpu-karpenter` (standard), `neuron` (Neuron drivers/runtime) and `gpu`
  (NVIDIA drivers). Each Capacity Block's reservation is attached to its
  hardware's NodeClass.

**Model cache** ([`model-bootstrap.tf`](terraform/model-bootstrap.tf))

- **S3 bucket** for the model weights, so nodes download them faster and
  privately instead of from HuggingFace. An S3 gateway VPC endpoint keeps that
  traffic on the AWS network instead of the NAT gateway. The bucket's layout
  mirrors each node's NVMe:

  | S3 | Node | Holds |
  |---|---|---|
  | `s3://<bucket>/<model>/` | `/tmp/models/<model>/` | weights |
  | `s3://<bucket>/<model>/cache/` | `/tmp/models/<model>/cache/` | Neuron compile cache |
  | `s3://<bucket>/benchmarks/` | - | benchmark results |

- **Permissions** (EKS Pod Identity): two service accounts, `model-uploader`
  (S3 read/write: the Jobs) and `model-reader` (S3 read-only: serving pods).
- **Cache Job:** one `model-weights-<model>` Job per `models` entry. It
  downloads the checkpoint from HuggingFace once and uploads it to S3.

**Serving containers** ([`serving-containers.tf`](terraform/serving-containers.tf))

- **ECR** hosts the serving container images, for faster, private pulls from
  inside the VPC.
- **CodeBuild** copies the vLLM-Neuron and vLLM images (§1) into ECR, and builds
  a Ray Serve image on top of each one with `ray_version`. Builds run in the
  background (about 15–20 minutes).
- **Image warmers:** two DaemonSets, `image-warmer-neuron` and
  `image-warmer-gpu`, pre-pull the multi-GB vLLM and Ray images from ECR onto
  every Neuron or GPU node as soon as it joins the cluster.

### 4. Check the infrastructure

```bash
$(terraform -chdir=terraform output -raw configure_kubectl)

kubectl get nodepools
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
kubectl wait --for=condition=complete job -l app=model-weights --timeout=60m
aws ecr describe-images --repository-name demo-neuron-eks/vllm-neuron --query 'imageDetails[].imageTags'
aws ecr describe-images --repository-name demo-neuron-eks/vllm-gpu --query 'imageDetails[].imageTags'
```

### 5. Export the outputs

Export the Terraform outputs the next sections use:

```bash
export AWS_REGION="$(terraform -chdir=terraform output -raw region)"
export S3_BUCKET_NAME="$(terraform -chdir=terraform output -raw model_storage_bucket)"
export VLLM_NEURON_IMAGE="$(terraform -chdir=terraform output -raw vllm_neuron_image)"
export VLLM_GPU_IMAGE="$(terraform -chdir=terraform output -raw vllm_gpu_image)"
```

## Section 2: Serving inference

### 1. Define serving parameters

Each node runs several vLLM replicas behind one Kubernetes Service. **This table
is the source of truth for serving:** the chart's values files below are filled in
from it.

| | trn2.48xlarge | p5.48xlarge |
|---|---|---|
| Replicas per node | 8 | 8 |
| Accelerators per replica | 2 Trainium2 devices (8 logical NeuronCores) | 1 H100 |
| Pod resources (cpu / memory) | 22 / 220Gi | 22 / 220Gi |
| `tensor_parallel_size` | 8 | 1 |
| `max_model_len` | 8192 | 8192 |
| `max_num_seqs` | 4 | 4 |
| `max_num_batched_tokens` | 1024 (prefill segment size) | 8192 |
| Common flags | `--enable-prefix-caching --no-disable-hybrid-kv-cache-manager` | same |
| Hardware-specific flags | `--hf-overrides={"quantization_config": {}}` (experts to BF16)<br>`--additional-config={"neuron_config": {"decode_context_length_buckets": [2048, 4096]}}` | `--dtype=bfloat16` |
| Env | `VLLM_NEURON_COMPILATION_TIMEOUT=1200`, `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1200`, `NEURON_SKIP_EFA_AFFINITY=1` | - |

The chart ships one values file per column, with these values filled in:
[`values-trn2-48xl.yaml`](vllm-serving/values-trn2-48xl.yaml) and
[`values-p5-48xl.yaml`](vllm-serving/values-p5-48xl.yaml) (every field is
documented in the chart's [`values.yaml`](vllm-serving/values.yaml)).
Review them against the table; the same file drives both the Neuron compile (§2)
and the deployment (§3):

The commands in the rest of this guide name the endpoints after these two
files. Set them once:

```bash
export TRN=trn2-48xl GPU=p5-48xl
cat vllm-serving/values-$TRN.yaml
cat vllm-serving/values-$GPU.yaml
```

### 2. Compile ahead of time for Neuron

On Trainium, the vLLM Neuron plugin compiles the model's graphs into NEFFs
(Neuron executables) before it can serve, which can take from tens of minutes to
hours. Compile once, ahead of time, and every replica starts from the cached
NEFFs in minutes.

The NEFF cache key covers the graph, its input shapes, the engine config and the
compiler/SDK version, so compile and serve with the **same image and the same
values file**. GPU needs no ahead-of-time step: vLLM builds its CUDA graphs at
startup, in minutes.

Neuron graphs have fixed shapes, so every request is padded up to the nearest
compiled bucket. For efficient prefill and decode, size the buckets to the
inputs and outputs you'll actually serve, and compile for them:

- **Prefill:** with `max_num_batched_tokens` below `max_model_len`, the plugin
  enables segmented prefill: prompts run in segments of exactly
  `max_num_batched_tokens` tokens, with a single prefill graph. ShareGPT prompts
  (the benchmark workload) are short: median ~135 tokens, p90 ~1K. A 1024
  segment fits about 90% of them in one pass and computes ~3x the useful
  prefill tokens, where 8192 computes ~21x.
- **Decode:** by default decode compiles one graph per batch size (1, 2, 4) at
  the full 8K context. `decode_context_length_buckets` adds graphs for 2K and 4K
  contexts, so short conversations decode against a smaller KV cache.

Run the chart in compile mode:

```bash
helm install $TRN-compile vllm-serving -f vllm-serving/values-$TRN.yaml --set mode=compile \
  --set region=$AWS_REGION --set s3Bucket=$S3_BUCKET_NAME --set image=$VLLM_NEURON_IMAGE

kubectl logs -f job/$TRN-compile -c compile
kubectl wait --for=condition=complete job/$TRN-compile --timeout=180m
```

[`compile-job.yaml`](vllm-serving/templates/compile-job.yaml) runs a Job with
one replica's resources (2 devices) on the trn2 node, in three containers:

1. **`model-download`:** syncs `s3://<bucket>/gpt-oss-20b/` (weights + any existing
   `cache/`) to the node's NVMe.
2. **`compile`:** runs `vllm bench latency` with the replica's engine flags.
   Building the engine compiles every graph into `VLLM_CACHE_ROOT`; a short
   latency test (128 input / 32 output tokens) proves they execute, and then it
   exits.
3. **`upload`:** syncs `cache/` back to `s3://<bucket>/gpt-oss-20b/cache/` and
   stores the latency result as `cache/results/$TRN-compile-latency.json`.

```bash
aws s3 ls s3://$S3_BUCKET_NAME/gpt-oss-20b/cache/ --recursive --summarize | tail -2
aws s3 cp s3://$S3_BUCKET_NAME/gpt-oss-20b/cache/results/$TRN-compile-latency.json - | jq
```

### 3. Deploy vLLM services

The chart's serve mode (the default) creates a Deployment with the table's
replicas and a Service in front of them. Each pod runs
`vllm serve /tmp/models/gpt-oss-20b` with the same engine flags as the compile
Job.

Serving pods include an init container that syncs the model dir from S3 to the node's NVMe.
Replicas on the same node share that NVMe, so the first one pulls the model and
the rest reuse it.

```bash
helm install gpt-oss-20b-$TRN vllm-serving -f vllm-serving/values-$TRN.yaml \
  --set region=$AWS_REGION --set s3Bucket=$S3_BUCKET_NAME --set image=$VLLM_NEURON_IMAGE

helm install gpt-oss-20b-$GPU vllm-serving -f vllm-serving/values-$GPU.yaml \
  --set region=$AWS_REGION --set s3Bucket=$S3_BUCKET_NAME --set image=$VLLM_GPU_IMAGE

kubectl rollout status deploy/gpt-oss-20b-$TRN --timeout=60m
kubectl rollout status deploy/gpt-oss-20b-$GPU --timeout=60m
kubectl get pods -l model=gpt-oss-20b -o wide
```

> **Cache miss?** If the trn2 values differ from what was compiled, every replica
> compiles at startup first (tens of minutes or more). To make a mismatch fail
> fast instead, add `--set env.VLLM_NEURON_DISABLE_WARMUP_COMPILE=1`: a cache miss
> then becomes an error.

#### Send requests

```bash
kubectl port-forward svc/gpt-oss-20b-$TRN 8080:8080 &
kubectl port-forward svc/gpt-oss-20b-$GPU 8081:8080 &

curl -s localhost:8080/v1/models | jq
curl -s localhost:8080/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "What is AWS Trainium?"}]}' | jq
```

The model id is the model directory. vLLM parses gpt-oss's harmony format, so
chat replies split `reasoning` from `content`. In-cluster clients use
`http://gpt-oss-20b-$TRN.default.svc.cluster.local:8080` and
`http://gpt-oss-20b-$GPU.default.svc.cluster.local:8080`; each Service spreads
requests across its replicas. Send a batch of requests (use `8081` for p5):

```bash
seq 1 200 | xargs -P 16 -I{} curl -s localhost:8080/v1/chat/completions -o /dev/null \
  -H "Content-Type: application/json" \
  -d '{"model": "/tmp/models/gpt-oss-20b", "messages": [{"role": "user", "content": "Hello"}]}'
```

### 4. (Optional) Deploy Ray Serve

<details>
<summary>Outdated: Ray Serve on the earlier trn2.3xlarge / p5.4xlarge setup (click to expand)</summary>

> **Outdated:** this section still targets the earlier trn2.3xlarge / p5.4xlarge
> setup and hasn't been updated for the 48xl nodes. It's kept for a later update.

The same scenarios on Ray Serve, deployed with plain manifests: a Ray head on
the x86 pool and a worker on the accelerator pool, running
[`vllm_ray_app.py`](ray/vllm_ray_app.py). The engine values are env vars in
[`ray-service-trn2.yaml`](ray/ray-service-trn2.yaml) and
[`ray-service-p5.yaml`](ray/ray-service-p5.yaml); they're already set to the Step 1
values, so check them against the table. An accelerator runs one endpoint at a
time, so free the node first:

```bash
helm uninstall gpt-oss-20b-trn2-3xl gpt-oss-20b-p5-4xl

export RAY_NEURON_IMAGE="$(terraform -chdir=terraform output -raw ray_neuron_image)"
export RAY_GPU_IMAGE="$(terraform -chdir=terraform output -raw ray_gpu_image)"

kubectl create configmap vllm-ray-app --from-file=ray/vllm_ray_app.py --dry-run=client -o yaml | kubectl apply -f -
envsubst '$RAY_NEURON_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-trn2.yaml | kubectl apply -f -
envsubst '$RAY_GPU_IMAGE $S3_BUCKET_NAME $AWS_REGION' < ray/ray-service-p5.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready rayservice/gpt-oss-20b-trn2-3xl-ray rayservice/gpt-oss-20b-p5-4xl-ray --timeout=60m
kubectl port-forward svc/gpt-oss-20b-trn2-3xl-ray-serve-svc 8000:8000 &
kubectl port-forward svc/gpt-oss-20b-p5-4xl-ray-serve-svc 8001:8000 &
```

Each head's dashboard is on port 8265:
`kubectl port-forward "$(kubectl get svc -l ray.io/node-type=head -o name | head -1)" 8265:8265`.

</details>

## Section 3: Observability

Terraform already deployed the observability stack (Section 1, step 3). This
section walks through what it measures, how it's collected and where to look.

### 1. Metrics

Three layers, from the hardware up to the requests:

| Layer | Exporter | Key metrics |
|---|---|---|
| Trainium | [neuron-monitor](terraform/manifests/neuron-monitor-daemonset.yaml) DaemonSet on every Neuron node (`:9010`) | `neuroncore_utilization_ratio`, `neuron_runtime_memory_used_bytes` (device memory), `execution_latency_seconds`, `execution_status_total` |
| GPU | NVIDIA DCGM exporter (GPU operator) on every GPU node | `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED` (GPU memory), `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP` |
| vLLM | Each vLLM replica's `/metrics` (same names on Neuron and GPU) | `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:generation_tokens_total`, `vllm:num_requests_running` / `_waiting`, `vllm:kv_cache_usage_perc`, `vllm:request_queue_time_seconds` |

Ray and Ray Serve metrics are also collected for the optional Ray deployment.

Look at the raw metrics on one replica and one node:

```bash
kubectl port-forward deploy/gpt-oss-20b-$TRN 8080:8080 &
curl -s localhost:8080/metrics | grep -E '^vllm:(num_requests|kv_cache_usage)'

NM=$(kubectl get pods -n monitoring -l app=neuron-monitor -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n monitoring "$NM" 9010:9010 &
curl -s localhost:9010/metrics | grep neuroncore_utilization_ratio | head
```

### 2. Collection

Prometheus (kube-prometheus-stack) scrapes every target **every second**, so
batching and queueing show up during a benchmark. What it scrapes is defined
by the ServiceMonitors and PodMonitors in [`scrape-configs/`](terraform/scrape-configs/):

| Scrape config | Target |
|---|---|
| [`metrics-enabled`](terraform/scrape-configs/metrics-enabled-servicemonitor.yaml) ServiceMonitor | Any Service labeled `metrics: enabled`, port `http`, `/metrics`. The vllm-serving chart sets that label, so every endpoint is scraped. |
| [`neuron-monitor`](terraform/scrape-configs/neuron-monitor-servicemonitor.yaml) ServiceMonitor | neuron-monitor DaemonSet |
| DCGM ServiceMonitor (created by the GPU operator) | DCGM exporter |
| [`ray-head`](terraform/scrape-configs/ray-head-podmonitor.yaml) / [`ray-workers`](terraform/scrape-configs/ray-workers-podmonitor.yaml) PodMonitors | Ray pods (optional Ray deployment) |

Check that every target is up:

```bash
kubectl get servicemonitor,podmonitor -A
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
```

Open <http://localhost:9090/targets>: the vLLM replicas, neuron-monitor and
DCGM should all be `UP`.

### 3. Visualization

Grafana loads every dashboard JSON under [`grafana-dashboards/`](terraform/grafana-dashboards/)
into the **Inference** folder:

| Dashboard | Answers |
|---|---|
| **vLLM** | What each endpoint delivers: TTFT, inter-token and end-to-end latency (p50/p95), output and prompt tokens/s, requests/s. Why it moves: running vs waiting requests, queue time, KV-cache usage, prefix-cache hits, preemptions. Pick endpoints with the **Endpoint** selector. |
| **Neuron (neuron-monitor)** | NeuronCore utilization, device memory, execution latency and errors per trn2 node |
| **GPU (DCGM)** | GPU utilization, memory, power and temperature per p5 node |
| **Ray Cluster / Ray Serve / Ray Serve Deployment (optional Ray deployment)** | Ray cluster, Serve applications and replicas. Empty unless the optional Ray step is running. |

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo    # user: admin
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:3000 &
```

Open <http://localhost:3000>, then **Dashboards → Inference → vLLM**. Send some
traffic (Section 2, step 3) and watch the latency and load rows react.

**Optional: reach Grafana without port-forwarding.** Expose it through an
internet-facing ALB that only your IP can reach
([`grafana-ingress.yaml`](observability/grafana-ingress.yaml); the AWS Load
Balancer Controller creates the ALB):

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
sed "s#ALLOWED_CIDR#$MY_IP/32#" observability/grafana-ingress.yaml | kubectl apply -f -
kubectl get ingress -n monitoring grafana -w
```

The ALB's DNS name shows under `ADDRESS` within a couple of minutes. Open
`http://<ADDRESS>` and sign in as above. The ALB serves plain HTTP; for
HTTPS add an ACM certificate (`alb.ingress.kubernetes.io/certificate-arn`). If
your IP changes, re-run the two commands to update the allowed CIDR.

## Section 4: Benchmark

### 1. Define test scenarios and metrics

The two endpoints only compare fairly if everything except the silicon is held
constant. Section 2 already fixed the serving side (same model, 8K context
window, 4 sequences per replica, 8 replicas per node). The benchmark fixes the
rest:

| Held constant | How |
|---|---|
| Workload | Real ShareGPT chat prompts: the first turn of each conversation, natural lengths, generation stops at EOS |
| Prompts and order | The dataset is read in file order, so every endpoint gets the identical prompts in the identical order |
| Load shape | The same tests and load stages for every endpoint |
| Measurement | One client-side tool, same metric definitions, plus each endpoint's own vLLM metrics for the same window |
| Cost basis | Per node: the whole node's $/hr, divided by the node's throughput |

Three questions, answered by two tests and one derived number:

| Test | Question | Load | Metrics |
|---|---|---|---|
| **chat-latency** | What's the best-case latency? | Constant 1 req/s for 60 s, far below saturation | TTFT, TPOT, request latency (p50/p95) |
| **chat-throughput** | How much can a node serve, and where does latency bend? | A sweep: probe the endpoint, then 5 stages from 1 req/s up to its estimated saturation, 60 s each. Stops early once the endpoint is past saturation (requests time out after 120 s; the run ends when half of them fail over 30 s). | Output tokens/s, achieved req/s, TTFT and TPOT per stage |
| **cost/performance** | What does a token cost? | *Derived* from the peak throughput stage | Output tokens per $, $ per 1M output tokens |

- **TTFT** (time to first token): queueing plus prefill, what a chat user waits for.
- **TPOT** (time per output token): decode speed after the first token, measured
  client-side. vLLM's server-side equivalent, shown live in Grafana, is
  inter-token latency (ITL).

### 2. Set up the benchmark tests

[inference-perf](https://github.com/kubernetes-sigs/inference-perf) is a
model-server-agnostic load generator from the Kubernetes Serving working group. It
talks to any OpenAI-compatible endpoint, so the same test runs unchanged against
vLLM on Neuron and vLLM on GPU.

The [`benchmark/`](benchmark/) Helm chart packages it. Everything shared lives in
[`benchmark/values.yaml`](benchmark/values.yaml): the dataset, the tests and their
load stages.
Each endpoint has its own small file that only sets its target: a label, its
in-cluster URL and a baseline hourly price (`hourlyUsd`; you pass your actual
node prices at install time in step 3):
[`values-trn2-48xl.yaml`](benchmark/values-trn2-48xl.yaml) and
[`values-p5-48xl.yaml`](benchmark/values-p5-48xl.yaml). Diff them: the target is
all that differs, so both endpoints run the identical tests and load.

```bash
diff benchmark/values-$TRN.yaml benchmark/values-$GPU.yaml
```

Confirm both endpoints answer from inside the cluster:

```bash
for e in gpt-oss-20b-$TRN gpt-oss-20b-$GPU; do
  kubectl run "check-$e" --rm -i --restart=Never --image=curlimages/curl -- \
    curl -s "http://$e.default.svc.cluster.local:8080/v1/models"
done
```

### 3. Deploy the test suite

One Helm release per endpoint, each running one Job. Start both together so
they run **in parallel** (they're on separate nodes, so they don't interfere)
and fill in the scoreboard side by side. Inside each Job the tests run
**sequentially**, latency first, so it measures with zero competing load before
the sweep saturates the endpoint.

```bash
helm upgrade --install bench-$TRN benchmark/ -f benchmark/values-$TRN.yaml \
  --set benchmark.storage.s3.bucketName=$S3_BUCKET_NAME \
  --set benchmark.target.hourlyUsd=<Trainium node $/hr>
helm upgrade --install bench-$GPU benchmark/ -f benchmark/values-$GPU.yaml \
  --set benchmark.storage.s3.bucketName=$S3_BUCKET_NAME \
  --set benchmark.target.hourlyUsd=<GPU node $/hr>

kubectl get jobs -l app.kubernetes.io/name=benchmark
kubectl logs -f -l benchmark.run=bench-$TRN
kubectl wait --for=condition=complete job -l app.kubernetes.io/name=benchmark --timeout=60m
```

A run takes about 10 minutes per endpoint. Watch it live on the **Benchmark
scoreboard** dashboard (Grafana, **Inference** folder; see Section 3 to open
Grafana): Trainium and GPU side by side, filling in as the load ramps. To
focus on one endpoint, **Benchmark - Trainium** and **Benchmark - GPU** show the
same panels for a single endpoint at full width.

The live latency is vLLM's server-side ITL; the final report in step 4 uses
the client-side TPOT.

Results land in `s3://<bucket>/benchmarks/<label>/`: the endpoint's cost basis
(`target.json`), and per test the client-side reports (overall and per load
stage) plus the endpoint's server-side vLLM metrics for the same window.

```bash
aws s3 ls s3://$S3_BUCKET_NAME/benchmarks/ --recursive | grep summary
```

**Iterate:** change the values (a test, a load stage, a price) and rerun the
same `helm upgrade --install` commands. Each run is a new Helm revision with a
fresh Job (`bench-<endpoint>-r<revision>`); Helm removes the previous run's Job,
stopping it if it's still running, so runs never overlap. Results are stored
per run (`<release>-r<revision>-<timestamp>`), and step 4 reports the newest.
`helm history bench-$TRN` lists an endpoint's runs, and
`helm get values bench-$TRN --revision <N>` shows the inputs of any of them.

### 4. Review results

[`benchmark/visualize.py`](benchmark/visualize.py) reads the latest run of each
target from S3 and prints them side by side:

```bash
benchmark/visualize.py --bucket $S3_BUCKET_NAME \
  --targets gpt-oss-20b-$TRN gpt-oss-20b-$GPU
```

1. **Latency at 1 req/s:** TTFT, TPOT and request latency, p50 and p95.
2. **Throughput sweep:** one table per endpoint, one row per load stage: requested
   vs achieved req/s, output tokens/s, TTFT and TPOT. Where achieved stops
   keeping up with requested, or TTFT climbs, is where the endpoint saturates.
3. **Cost/performance:** the peak error-free stage's output tokens/s against the
   node's $/hr, as output tokens per $ and $ per 1M output tokens.

Read the numbers with the setup in mind. Both endpoints serve the same
checkpoint, but Trainium2 runs the MoE experts in BF16 while H100 keeps them in
MXFP4. Both are configured for 4 sequences per replica, which favors latency
over peak throughput. Raise `max_num_seqs` on both to measure a
throughput-oriented setup.

## Section 5: Teardown

Remove what you deployed, then the infrastructure. Terraform deletes the
Karpenter node pools first and waits until Karpenter has terminated their
instances, then the cluster, and the VPC last.

```bash
helm list -q | xargs -r -n1 helm uninstall
kubectl delete ingress -n monitoring grafana --ignore-not-found   # removes its ALB before destroy
kubectl delete rayservice --all
terraform -chdir=terraform destroy
```

> **This is irreversible.** `terraform destroy` deletes the EKS cluster, the
> nodes, the ECR images and the S3 bucket (weights, compile cache, benchmark
> results). Back up anything you want to keep from S3 first. Capacity Blocks are
> paid for their full term whether or not instances run.
