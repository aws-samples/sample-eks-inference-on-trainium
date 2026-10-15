{{/* Chart name */}}
{{- define "benchmark.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/*
Job / ConfigMap name: <release>-r<revision>. The Helm revision makes every
`helm upgrade --install` a fresh Job (a Job's spec is immutable), and Helm
deletes the previous revision's Job. Pass { root, t }.
*/}}
{{- define "benchmark.targetName" -}}
{{- $suffix := printf "-r%d" .root.Release.Revision -}}
{{- .root.Release.Name | trunc (int (sub 63 (len $suffix))) | trimSuffix "-" -}}{{ $suffix }}
{{- end -}}

{{/*
Resolve the endpoint under test. Returns JSON: { label, baseUrl, hourlyUsd,
endpoint, serving }.
  target.endpoint set: read the vllm-serving release's <endpoint>-serving-config
    ConfigMap (Helm lookup, at install/upgrade) for its URL, and keep its
    serving.json to store with every result.
  target.baseUrl set instead: any OpenAI-compatible endpoint; no serving config.
*/}}
{{- define "benchmark.target" -}}
{{- $t := .Values.benchmark.target -}}
{{- $out := dict "hourlyUsd" $t.hourlyUsd "endpoint" ($t.endpoint | default "") "serving" "" -}}
{{- if $t.endpoint -}}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace (printf "%s-serving-config" $t.endpoint) | default dict -}}
{{- $serving := dig "data" "serving.json" "" $cm -}}
{{- if not $serving -}}
{{- fail (printf "endpoint %q not found: no ConfigMap %s-serving-config in namespace %q. Deploy it with the vllm-serving chart (release name = endpoint), or set benchmark.target.baseUrl for another endpoint. (helm template / --dry-run=client can't read the cluster.)" $t.endpoint $t.endpoint .Release.Namespace) -}}
{{- end -}}
{{- $_ := set $out "serving" $serving -}}
{{- $_ := set $out "baseUrl" ($t.baseUrl | default ($serving | fromJson).baseUrl) -}}
{{- $_ := set $out "label" ($t.label | default $t.endpoint) -}}
{{- else if $t.baseUrl -}}
{{- $_ := set $out "baseUrl" $t.baseUrl -}}
{{- $_ := set $out "label" (required "benchmark.target.label is required with target.baseUrl" $t.label) -}}
{{- else -}}
{{- fail "set benchmark.target.endpoint (a vllm-serving release) or benchmark.target.baseUrl - e.g. -f benchmark/values-trn2-48xl.yaml" -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Labels. Pass { root, t }. */}}
{{- define "benchmark.labels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
benchmark.run: {{ .root.Release.Name }}
benchmark.revision: {{ .root.Release.Revision | quote }}
benchmark.target: {{ .t.label }}
{{- end -}}

{{/*
inference-perf config for one test against the target. Pass a dict:
{ b: <benchmark values>, t: <target>, cfg: <test config>, test: <test name>,
run: <run id> }. Rendered once per test into the ConfigMap so the Job can run
them sequentially.
*/}}
{{- define "benchmark.config" -}}
{{- $b := .b -}}
{{- $cfg := .cfg -}}
{{- $test := .test -}}
{{- $t := .t -}}
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
  {{- with $cfg.stopAtSaturation }}
  {{- if .enabled }}
  # A request still unanswered after requestTimeoutSeconds fails; the breaker
  # below opens when too many fail, and (it never resets) ends the run there.
  request_timeout: {{ .requestTimeoutSeconds }}
  circuit_breakers: ["saturation"]
  {{- end }}
  {{- end }}

{{- with $cfg.stopAtSaturation }}
{{- if .enabled }}

# Stop at saturation: once the endpoint can't keep up, queued requests time out.
# Open when at least errorRate of the requests finished in the last
# windowSeconds failed (min minSamples).
circuit_breakers:
  - name: saturation
    metrics:
      matches: ["start_time"]   # every request
      rules: ["error"]          # hit = the request failed (incl. timed out)
    triggers:
      - type: rate_over_window
        window_sec: {{ .windowSeconds }}
        threshold: {{ .errorRate }}
        min_samples: {{ .minSamples }}
{{- end }}
{{- end }}

server:
  type: {{ $b.server.type }}
  model_name: {{ $b.server.modelName }}
  base_url: {{ $t.baseUrl | toString }}
  ignore_eos: {{ $cfg.ignoreEos | default false }}

tokenizer:
  pretrained_model_name_or_path: {{ $b.server.tokenizerPath }}

{{- with $b.metrics.prometheus }}
{{- if .enabled }}
{{- $svc := first (splitList "." (first (splitList ":" (urlParse (toString $t.baseUrl)).host))) }}

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
    path: "{{ $b.storage.s3.pathPrefix }}/{{ $t.label }}/{{ $test }}/{{ .run }}"
{{- end -}}
