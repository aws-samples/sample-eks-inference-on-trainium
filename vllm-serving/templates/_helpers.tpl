{{/* Validate the required values once; every template includes this. */}}
{{- define "vllm-serving.validate" -}}
{{- range $k := list "region" "s3Bucket" "image" "model" "hardware" -}}
{{- if not (index $.Values $k) -}}
{{- fail (printf "%s is required (see values.yaml and the README's Step 1 table)" $k) -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.hardware (list "neuron" "gpu")) -}}
{{- fail (printf "hardware must be neuron or gpu, got %q" .Values.hardware) -}}
{{- end -}}
{{- if not (has .Values.mode (list "serve" "compile" "warmup" "bench")) -}}
{{- fail (printf "mode must be serve, compile, warmup or bench, got %q" .Values.mode) -}}
{{- end -}}
{{- if and (has .Values.mode (list "compile" "warmup")) (ne .Values.hardware "neuron") -}}
{{- fail (printf "mode=%s is Neuron only (GPU engines build at startup)" .Values.mode) -}}
{{- end -}}
{{- if and .Values.ingress.groupName (not .Values.ingress.host) -}}
{{- fail "ingress.groupName needs ingress.host: releases sharing an ALB are routed by host" -}}
{{- end -}}
{{- end -}}

{{/* Common labels */}}
{{- define "vllm-serving.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: {{ .Release.Name }}
model: {{ .Values.model }}
{{- end -}}

{{/* Pod selector labels */}}
{{- define "vllm-serving.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end -}}

{{/* Model dir on the node (weights) - also the API model id. */}}
{{- define "vllm-serving.modelDir" -}}
{{ .Values.paths.models }}/{{ .Values.model }}
{{- end -}}

{{/* DRA DeviceClass of the hardware's devices. */}}
{{- define "vllm-serving.deviceClass" -}}
{{ ternary "neuron.aws.com" "gpu.nvidia.com" (eq .Values.hardware "neuron") }}
{{- end -}}

{{/* Taint key of the hardware's NodePools. */}}
{{- define "vllm-serving.taintKey" -}}
{{ ternary "aws.amazon.com/neuron" "nvidia.com/gpu" (eq .Values.hardware "neuron") }}
{{- end -}}

{{/* True (non-empty) when this pod runs on the accelerators: serve, warmup,
bench, and compile when compile.nodepool is empty (or the serving nodepool). */}}
{{- define "vllm-serving.onDevice" -}}
{{- if or (ne .Values.mode "compile") (not .Values.compile.nodepool) (eq .Values.compile.nodepool .Values.nodepool) }}true{{ end -}}
{{- end -}}

{{/* Node label every NodePool of the hardware sets. */}}
{{- define "vllm-serving.deviceNodeLabel" -}}
{{ ternary "neuron.amazonaws.com/neuron-device" "nvidia.com/gpu" (eq .Values.hardware "neuron") }}
{{- end -}}

{{/*
vLLM engine flags (the scenario). Shared by both modes, so compile and serve
build the same engine config - and on Neuron, the same NEFF cache keys.
*/}}
{{- define "vllm-serving.engineArgs" -}}
{{- $dir := include "vllm-serving.modelDir" . -}}
{{- $v := .Values.vllm -}}
{{- $argv := list "--tokenizer" $dir
  (printf "--tensor-parallel-size=%v" $v.tensorParallelSize)
  (printf "--max-model-len=%v" $v.maxModelLen)
  (printf "--max-num-seqs=%v" $v.maxNumSeqs)
  (printf "--max-num-batched-tokens=%v" $v.maxNumBatchedTokens) -}}
{{- concat $argv ($v.commonArgs | default list) ($v.extraArgs | default list) | toJson -}}
{{- end -}}

{{/*
Container env. VLLM_CACHE_ROOT is per pod (an emptyDir on node NVMe): what's
worth reusing is on EFS (below), the rest goes with the pod.
On Neuron also: LNC 2; the shared cache on EFS - native NEFFs
(TORCH_NEURONX_NEFF_CACHE_DIR) and XLA/NKI graphs (NEURON_LIBTORCH_REMOTE_CACHE);
compile/warmup: a manifest of the graphs; compile: CPU compile when off the
devices. Then the scenario's env.
*/}}
{{- define "vllm-serving.env" -}}
- name: VLLM_CACHE_ROOT
  value: {{ include "vllm-serving.cacheRoot" . }}
{{- if eq .Values.hardware "neuron" }}
- name: NEURON_LOGICAL_NC_CONFIG
  value: "2"
# The native route, named: the plugin defaults to it anyway, but only the named
# route turns on the precompile (Dynamo) cache, which lets a warm start on the
# same node skip re-tracing every graph.
- name: VLLM_NEURON_BACKEND
  value: neuron_native
# Every mode, not just CPU compile: some kernels pick their graph from the
# platform target at import, and the runtime probe can fail there, so a pod that
# detects it traces different graphs (different cache keys) than a CPU compile.
- name: NEURON_PLATFORM_TARGET_OVERRIDE
  value: {{ .Values.neuron.platformTarget | quote }}
- name: TORCH_NEURONX_NEFF_CACHE_DIR
  value: {{ .Values.neuronCache.mountPath }}/{{ include "vllm-serving.cacheKey" . }}/native-neff
- name: NEURON_LIBTORCH_REMOTE_CACHE
  value: {{ .Values.neuronCache.mountPath }}/{{ include "vllm-serving.cacheKey" . }}/xla
{{- if has .Values.mode (list "compile" "warmup") }}
- name: NEURON_LIBTORCH_PARALLEL_COMPILE_WORKERS
  value: {{ .Values.compile.workers | quote }}
- name: VLLM_NEURON_MANIFEST_DIR
  value: {{ .Values.neuronCache.mountPath }}/{{ include "vllm-serving.cacheKey" . }}/manifests/{{ .Release.Name }}
{{- end }}
{{- if eq .Values.mode "compile" }}
{{- if not (include "vllm-serving.onDevice" .) }}
- name: VLLM_NEURON_CPU_COMPILE
  value: "1"
{{- end }}
{{- end }}
{{- end }}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end -}}

{{/* Name of the release's ResourceClaimTemplate. */}}
{{- define "vllm-serving.claimTemplate" -}}
{{ .Release.Name }}-devices
{{- end -}}

{{/* Pod-level resourceClaims, placed in the pod spec (pods on the devices). */}}
{{- define "vllm-serving.podClaims" -}}
{{- if include "vllm-serving.onDevice" . }}
resourceClaims:
  - name: devices
    resourceClaimTemplateName: {{ include "vllm-serving.claimTemplate" . }}
{{- end }}
{{- end -}}

{{/* Where the pod runs: any node of the hardware (any trn2 size - the DRA
claim decides whether the devices fit), or nodepool if set; or the CPU compile
pool. */}}
{{- define "vllm-serving.scheduling" -}}
{{- if include "vllm-serving.onDevice" . }}
nodeSelector:
  {{- if .Values.nodepool }}
  karpenter.sh/nodepool: {{ .Values.nodepool }}
  {{- else }}
  {{ include "vllm-serving.deviceNodeLabel" . }}: "true"
  {{- end }}
tolerations:
  - key: {{ include "vllm-serving.taintKey" . }}
    operator: Exists
    effect: NoSchedule
  - key: karpenter
    operator: Exists
    effect: NoSchedule
{{- else }}
nodeSelector:
  karpenter.sh/nodepool: {{ .Values.compile.nodepool }}
tolerations:
  - key: karpenter
    operator: Exists
    effect: NoSchedule
{{- end }}
{{- end -}}

{{/* vLLM container resources: cpu/memory + the release's DRA claim (pods on
the devices), or the CPU compile Job's size. */}}
{{- define "vllm-serving.resources" -}}
{{- if include "vllm-serving.onDevice" . }}
{{- $r := .Values.resources -}}
{{- range $kind := list "requests" "limits" }}
{{ $kind }}:
  {{- with $r.cpu }}
  cpu: {{ . | quote }}
  {{- end }}
  {{- with $r.memory }}
  memory: {{ . }}
  {{- end }}
{{- end }}
claims:
  - name: devices
{{- else }}
{{- $c := .Values.compile }}
requests:
  cpu: {{ $c.cpu | quote }}
  memory: {{ $c.memory }}
  ephemeral-storage: {{ $c.ephemeralStorage }}
limits:
  memory: {{ $c.memory }}
{{- end }}
{{- end -}}

{{/*
Init container: wait for the model-weights-<model> Job's ready marker, then pull
the weights from S3 to the model dir (node NVMe; an emptyDir for CPU compile),
minus the checkpoint's original/ and metal/ copies, which vLLM doesn't load.
sync (CRT) is incremental: a warm node transfers nothing. Replicas on the same
node share the NVMe, so the sync holds a file lock (the image has python3 but no
flock). The compile cache isn't in S3: it's on the shared EFS volume.
*/}}
{{- define "vllm-serving.modelDownload" -}}
{{- $dir := include "vllm-serving.modelDir" . -}}
{{- $s3 := printf "s3://%s/%s" .Values.s3Bucket .Values.model -}}
- name: model-download
  image: {{ .Values.awsCliImage }}
  command: ["/bin/bash", "-c"]
  env:
    - name: AWS_REGION
      value: {{ .Values.region }}
  args:
    - |
      set -euo pipefail
      until aws s3 ls "{{ $s3 }}/.ready/weights" >/dev/null 2>&1; do
        echo "Waiting for {{ $s3 }}/.ready/weights (model-weights-{{ .Values.model }} Job)..."; sleep 30
      done
      aws configure set s3.preferred_transfer_client crt
      python3 -c 'import fcntl,subprocess,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); sys.exit(subprocess.call(sys.argv[2:]))' \
        {{ .Values.paths.models }}/.{{ .Values.model }}.sync.lock \
        aws s3 sync "{{ $s3 }}/" "{{ $dir }}/" --exclude ".ready/*" --exclude "cache*" --exclude "original/*" --exclude "metal/*"
      # Runs as root; vLLM may not (the Ray images run as `ray`) and writes lock
      # files / fetched graphs into the local cache.
      chmod -R a+rwX "{{ $dir }}"
      du -sh "{{ $dir }}"
  volumeMounts:
    - name: local-storage
      mountPath: {{ .Values.paths.models }}
{{- end -}}

{{/* Volume mounts of the vLLM container: the weights (node NVMe), the per-pod
vLLM cache, and on Neuron the shared cache on EFS. */}}
{{- define "vllm-serving.volumeMounts" -}}
- name: dshm
  mountPath: /dev/shm
- name: local-storage
  mountPath: {{ .Values.paths.models }}
- name: vllm-cache
  mountPath: {{ include "vllm-serving.cacheRoot" . }}
{{- if eq .Values.hardware "neuron" }}
- name: neuron-cache
  mountPath: {{ .Values.neuronCache.mountPath }}
# The precompile (Dynamo) cache - the traced graphs, which let a start skip
# re-tracing - lives under VLLM_CACHE_ROOT. Mount its directory from the shared
# cache, so a start on any node finds the packages a compile, warmup or earlier
# pod saved. The rest of VLLM_CACHE_ROOT stays with the pod.
- name: neuron-cache
  mountPath: {{ include "vllm-serving.cacheRoot" . }}/neuron/torch_compile
  subPath: {{ include "vllm-serving.cacheKey" . }}/torch-compile
{{- end }}
{{- end -}}

{{/* Volumes: shared memory, the model dir (node NVMe, or an emptyDir on the CPU
compile node, which has none), the per-pod vLLM cache (emptyDir: node NVMe via
the node class's instanceStorePolicy RAID0) and the shared Neuron cache. */}}
{{- define "vllm-serving.volumes" -}}
- name: dshm
  emptyDir:
    medium: Memory
- name: local-storage
{{- if include "vllm-serving.onDevice" . }}
  hostPath:
    path: {{ .Values.paths.nodeLocal }}
    type: Directory
{{- else }}
  emptyDir:
    sizeLimit: {{ .Values.compile.ephemeralStorage }}
{{- end }}
- name: vllm-cache
  emptyDir: {}
{{- if eq .Values.hardware "neuron" }}
- name: neuron-cache
  persistentVolumeClaim:
    claimName: {{ .Values.neuronCache.pvc }}
{{- end }}
{{- end -}}

{{/* Cache key: a hash of the image. The shared cache on EFS sits under it, so
two images never share compiled graphs. Neuron cache keys cover the compiler inputs and SDK versions but not
kernel or model source, so a patched build with the same versions (e.g. a
pip-installed vLLM-Neuron fork) would otherwise load the stock image's NEFFs. */}}
{{- define "vllm-serving.cacheKey" -}}
{{ sha1sum .Values.image | trunc 10 }}
{{- end -}}

{{- define "vllm-serving.cacheRoot" -}}
/var/cache/vllm
{{- end -}}
