{{/* Validate the required values once; every template includes this. */}}
{{- define "vllm-serving.validate" -}}
{{- range $k := list "region" "s3Bucket" "image" "model" "hardware" "nodepool" -}}
{{- if not (index $.Values $k) -}}
{{- fail (printf "%s is required (see values.yaml and the README's Step 1 table)" $k) -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.hardware (list "neuron" "gpu")) -}}
{{- fail (printf "hardware must be neuron or gpu, got %q" .Values.hardware) -}}
{{- end -}}
{{- if not (has .Values.mode (list "serve" "compile")) -}}
{{- fail (printf "mode must be serve or compile, got %q" .Values.mode) -}}
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

{{/* Accelerator resource name for the hardware. */}}
{{- define "vllm-serving.deviceResource" -}}
{{ ternary "aws.amazon.com/neuron" "nvidia.com/gpu" (eq .Values.hardware "neuron") }}
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

{{/* Container env: the compile cache dir (inside the model dir) + the scenario's env. */}}
{{- define "vllm-serving.env" -}}
- name: VLLM_CACHE_ROOT
  value: {{ include "vllm-serving.modelDir" . }}/{{ .Values.cacheDir }}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end -}}

{{/* Name of the release's Neuron ResourceClaimTemplate. */}}
{{- define "vllm-serving.claimTemplate" -}}
{{ .Release.Name }}-neuron
{{- end -}}

{{/* Pod-level resourceClaims (Neuron), placed in the pod spec. */}}
{{- define "vllm-serving.podClaims" -}}
{{- if eq .Values.hardware "neuron" }}
resourceClaims:
  - name: neurons
    resourceClaimTemplateName: {{ include "vllm-serving.claimTemplate" . }}
{{- end }}
{{- end -}}

{{/* Taints of the accelerator NodePools. */}}
{{- define "vllm-serving.tolerations" -}}
- key: {{ include "vllm-serving.deviceResource" . }}
  operator: Exists
  effect: NoSchedule
- key: karpenter
  operator: Exists
  effect: NoSchedule
{{- end -}}

{{/* Serving container resources: cpu/memory + accelerators (GPU: device
resource; Neuron: the release's DRA claim). */}}
{{- define "vllm-serving.resources" -}}
{{- $r := .Values.resources -}}
{{- range $kind := list "requests" "limits" }}
{{ $kind }}:
  {{- with $r.cpu }}
  cpu: {{ . | quote }}
  {{- end }}
  {{- with $r.memory }}
  memory: {{ . }}
  {{- end }}
  {{- if ne $.Values.hardware "neuron" }}
  {{ include "vllm-serving.deviceResource" $ }}: {{ $r.devices | quote }}
  {{- end }}
{{- end }}
{{- if eq .Values.hardware "neuron" }}
claims:
  - name: neurons
{{- end }}
{{- end -}}

{{/*
Init container: wait for the model-weights-<model> Job's ready marker, then pull
the model dir (weights + compile cache/, minus the non-portable NKI kernel cache)
from S3 to the node's NVMe. sync (CRT)
is incremental: a warm node transfers nothing. Replicas on the same node share
the NVMe, so the sync holds a file lock (the image has python3 but no flock).
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
        aws s3 sync "{{ $s3 }}/" "{{ $dir }}/" --exclude ".ready/*" \
          --exclude "cache*" --include "{{ .Values.cacheDir }}/*" --exclude "{{ .Values.cacheDir }}/neuron/compile_cache/nki/*"
      mkdir -p "{{ $dir }}/{{ .Values.cacheDir }}"
      # Only this release's cache dir (cacheDir) is pulled. The NKI kernel cache
      # (<cacheDir>/neuron/compile_cache/nki/) is node-local and
      # never synced: its entries point at kernel binaries in
      # /var/tmp/nki-intermediate-cache, mounted from this same NVMe below.
      # Runs as root; vLLM may not (the Ray images run as `ray`) and writes lock
      # files / new graphs into the cache.
      chmod -R a+rwX "{{ $dir }}"
      du -sh "{{ $dir }}" "{{ $dir }}/{{ .Values.cacheDir }}"
  volumeMounts:
    - name: local-storage
      mountPath: {{ .Values.paths.models }}
    {{- include "vllm-serving.nkiCacheMount" . | nindent 4 }}
{{- end -}}

{{/*
NKI kernel binaries, kept on the node's NVMe so the NKI cache entries in
VLLM_CACHE_ROOT stay valid across pods on the same node. Mount it in every
container that runs vLLM, and in the model-download init container. One per
cacheDir, like the compile cache (kernel changes aren't part of the cache key).
*/}}
{{- define "vllm-serving.nkiCacheMount" -}}
- name: local-storage
  mountPath: /var/tmp/nki-intermediate-cache
  subPath: .nki-intermediate-{{ .Values.cacheDir }}
{{- end -}}

