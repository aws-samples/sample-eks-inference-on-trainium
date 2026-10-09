{{/* Common labels */}}
{{- define "platform.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Resolve one profile into everything the catalog publishes. Pass a dict:
{ root: $, name: <profile name>, p: <profile values> }. Returns JSON (use
fromJson) with:
  env         env vars for vllm-profile-<name> (serve flags, S3 paths, cache dir)
  spec        placement + image, published as the serving.platform/spec annotation
  configHash  hash of the profile definition (immutability check)
  compileJob  compile Job name ("" for hardware without a compile step)
*/}}
{{- define "platform.resolve" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $name := .name -}}
{{- $p := .p -}}
{{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) (gt (len $name) 40) -}}
{{- fail (printf "profile %q: name must be lowercase letters, digits and '-', max 40 chars" $name) -}}
{{- end -}}
{{- $hw := index $v.hardware ($p.hardware | default "") -}}
{{- if not $hw -}}
{{- fail (printf "profile %q: hardware %q not in .Values.hardware (%s)" $name ($p.hardware | default "") (keys $v.hardware | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $image := index $v.images $hw.imageKey | default "" -}}
{{- if not $image -}}
{{- fail (printf "profile %q: images.%s is not set" $name $hw.imageKey) -}}
{{- end -}}
{{- range $k := list "nodepool" "devices" "tensorParallelSize" "maxModelLen" "maxNumSeqs" "maxNumBatchedTokens" -}}
{{- if not (hasKey $p $k) -}}
{{- fail (printf "profile %q: missing required field %q" $name $k) -}}
{{- end -}}
{{- end -}}
{{- $modelDir := printf "%s/%s" $v.paths.models (required "model.name is required" $v.model.name) -}}
{{- $env := dict
  "SERVING_PROFILE" $name
  "AWS_REGION" (required "region is required" $v.region)
  "MODEL_ID" $modelDir
  "VLLM_CACHE_ROOT" (printf "%s/cache" $modelDir)
  "S3_MODEL_URI" (required "s3.modelUri is required" $v.s3.modelUri)
  "S3_CACHE_URI" (printf "%s/cache" $v.s3.modelUri)
  "S3_WEIGHTS_READY_URI" (required "s3.weightsReadyUri is required" $v.s3.weightsReadyUri)
  "TENSOR_PARALLEL_SIZE" (toString $p.tensorParallelSize)
  "MAX_MODEL_LEN" (toString $p.maxModelLen)
  "MAX_NUM_SEQS" (toString $p.maxNumSeqs)
  "MAX_NUM_BATCHED_TOKENS" (toString $p.maxNumBatchedTokens)
  "HF_OVERRIDES" ($p.hfOverrides | default "")
  "ADDITIONAL_CONFIG" ($p.additionalConfig | default "")
-}}
{{- if eq $p.hardware "neuron" -}}
{{- $_ := set $env "NEURON_CORES" (toString $p.tensorParallelSize) -}}
{{- $_ := set $env "NEURON_RT_NUM_CORES" (toString $p.tensorParallelSize) -}}
{{- end -}}
{{- if $hw.compile -}}
{{- /*
One shared cache dir for every profile and image (entries are keyed by a hash of
graph + shapes + compiler/SDK version, so they never collide). The per-profile
marker records that this profile was compiled with this image.
*/ -}}
{{- $_ := set $env "S3_CACHE_READY_URI" (printf "%s/.ready/cache/%s/%s" $v.s3.modelUri (regexReplaceAll "^.*:" $image "") $name) -}}
{{- end -}}
{{- range $k, $val := $hw.env -}}
{{- $_ := set $env $k (toString $val) -}}
{{- end -}}
{{- range $k, $val := ($p.env | default dict) -}}
{{- $_ := set $env $k (toString $val) -}}
{{- end -}}
{{- $compileJob := "" -}}
{{- if $hw.compile -}}
{{- $compileJob = printf "model-compile-%s-%s" $name (sha256sum (printf "%s|%s" (toJson $env) $image) | trunc 8) -}}
{{- end -}}
{{- $spec := dict
  "profile" $name
  "model" $v.model.name
  "hardware" $p.hardware
  "nodepool" $p.nodepool
  "devices" $p.devices
  "deviceResource" $hw.deviceResource
  "tolerations" $hw.tolerations
  "resources" ($p.resources | default dict)
  "image" $image
  "rayImage" (ternary ($v.images.neuronRay | default "") "" (eq $p.hardware "neuron"))
  "rayVersion" ($v.ray.version | default "")
  "awsCliImage" $v.images.awsCli
  "serviceAccount" $v.serviceAccounts.reader
  "nodeLocalPath" $v.paths.nodeLocal
  "modelsPath" $v.paths.models
  "compileJob" $compileJob
-}}
{{- dict "env" $env "spec" $spec "configHash" (sha256sum (toJson $p) | trunc 16) "compileJob" $compileJob "hw" $hw "image" $image | toJson -}}
{{- end -}}
