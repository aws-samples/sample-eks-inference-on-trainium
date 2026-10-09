{{/* Chart name */}}
{{- define "benchmark.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/* Fully qualified name: <release>-<label> so vllm/ray runs never collide */}}
{{- define "benchmark.fullname" -}}
{{- printf "%s-%s" .Release.Name .Values.benchmark.target.label | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "benchmark.labels" -}}
app.kubernetes.io/name: {{ include "benchmark.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
benchmark.target: {{ .Values.benchmark.target.label }}
{{- end -}}

{{/*
inference-perf config for one test. Pass a dict: { b: <benchmark values>,
cfg: <test config>, test: <test name> }. Rendered once per test into the
ConfigMap so a single Job can run them sequentially.
*/}}
{{- define "benchmark.config" -}}
{{- $b := .b -}}
{{- $cfg := .cfg -}}
{{- $test := .test -}}
{{- $dtype := $cfg.data.type | default "synthetic" -}}
api:
  type: {{ $b.api.type }}
  streaming: {{ $b.api.streaming }}

data:
  type: {{ $dtype }}
  {{- if or (eq $dtype "synthetic") (eq $dtype "random") }}
  # total_count sizes the precomputed length arrays; inference-perf indexes into
  # them per request, so it MUST be >= the total requests a run makes.
  input_distribution:
    total_count: {{ $cfg.data.totalCount | default 100000 }}
    mean: {{ $cfg.data.input.mean }}
    std_dev: {{ $cfg.data.input.stdDev }}
    min: {{ $cfg.data.input.min }}
    max: {{ $cfg.data.input.max }}
  output_distribution:
    total_count: {{ $cfg.data.totalCount | default 100000 }}
    mean: {{ $cfg.data.output.mean }}
    std_dev: {{ $cfg.data.output.stdDev }}
    min: {{ $cfg.data.output.min }}
    max: {{ $cfg.data.output.max }}
  {{- else if $cfg.data.path }}
  # Dataset types (shareGPT, ...) draw real prompts. shareGPT auto-downloads from
  # HuggingFace when no path is set; set data.path to load from a staged file.
  path: {{ $cfg.data.path | quote }}
  {{- end }}

load:
  type: {{ $cfg.load.type }}
  num_workers: {{ $cfg.load.numWorkers }}
  {{- if $cfg.load.sweep }}
  stages: []
  sweep:
    type: {{ $cfg.load.sweep.type }}
    num_requests: {{ $cfg.load.sweep.numRequests }}
    timeout: {{ $cfg.load.sweep.timeout }}
    num_stages: {{ $cfg.load.sweep.numStages }}
    stage_duration: {{ $cfg.load.sweep.stageDuration }}
    saturation_percentile: {{ $cfg.load.sweep.saturationPercentile }}
  {{- else }}
  stages:
    {{- range $cfg.load.stages }}
    - rate: {{ .rate }}
      duration: {{ .duration }}
    {{- end }}
  {{- end }}

server:
  type: {{ $b.target.serverType }}
  model_name: {{ $b.target.modelName }}
  base_url: {{ $b.target.baseUrl }}
  ignore_eos: {{ if hasKey $cfg "ignoreEos" }}{{ $cfg.ignoreEos }}{{ else }}{{ $b.target.ignoreEos }}{{ end }}

tokenizer:
  pretrained_model_name_or_path: {{ $b.target.tokenizerPath }}

{{- with $b.metrics.prometheus }}
{{- if .enabled }}
{{- $svc := .service | default (first (splitList "." (first (splitList ":" (urlParse $b.target.baseUrl).host)))) }}

# Server-side vLLM metrics for this target, queried from Prometheus.
metrics:
  type: prometheus
  prometheus:
    url: {{ .url }}
    scrape_interval: {{ .scrapeInterval }}
    filters:
      - "service='{{ $svc }}'"
      {{- range .extraFilters }}
      - {{ . | quote }}
      {{- end }}

report:
  prometheus:
    summary: true
    per_stage: {{ .perStage }}
{{- end }}
{{- end }}

storage:
  simple_storage_service:
    bucket_name: {{ $b.storage.s3.bucketName | quote }}
    path: "{{ $b.storage.s3.pathPrefix }}/{{ $b.target.label }}/{{ $test }}/{{ randAlpha 12 }}"
{{- end -}}
