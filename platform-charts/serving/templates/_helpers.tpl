{{/*
Endpoints with defaults merged in. Returns JSON (use fromJson) list of
{ name, ep }. Templates range over it and build a ctx { root: $, name, ep }.
*/}}
{{- define "serving.endpoints" -}}
{{- $out := list -}}
{{- range $name, $vals := .Values.endpoints -}}
{{- if or (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $name)) (gt (len $name) 40) -}}
{{- fail (printf "endpoint %q: name must start with a letter and use lowercase letters, digits and '-', max 40 chars" $name) -}}
{{- end -}}
{{- $ep := mergeOverwrite (deepCopy $.Values.defaults) (deepCopy ($vals | default dict)) -}}
{{- $out = append $out (dict "name" $name "ep" $ep) -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Common labels. Pass ctx. */}}
{{- define "serving.labels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
serving.platform/endpoint: {{ .name }}
serving.platform/profile: {{ .ep.profile }}
{{- end -}}

{{/* Pod selector labels. Pass ctx. */}}
{{- define "serving.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
serving.platform/endpoint: {{ .name }}
{{- end -}}

{{/*
Read the endpoint's profile from the platform catalog and validate the request.
Pass ctx. Returns JSON (use fromJson): { env, spec, scripts, offProfile }.
  env      profile env (+ overrides when allowOffProfile)
  spec     placement + image (serving.platform/spec annotation)
  scripts  vended launch scripts (vllm-serve-script ConfigMap)
*/}}
{{- define "serving.profile" -}}
{{- $root := .root -}}
{{- $ep := .ep -}}
{{- $ns := $root.Values.platformNamespace | default $root.Release.Namespace -}}
{{- $name := required (printf "endpoint %q: profile is required - list them with: kubectl get cm -l serving.platform/profile" .name) $ep.profile -}}
{{- $cm := lookup "v1" "ConfigMap" $ns (printf "vllm-profile-%s" $name) | default dict -}}
{{- $specJson := dig "metadata" "annotations" "serving.platform/spec" "" $cm -}}
{{- if not $specJson -}}
{{- $avail := list -}}
{{- range (dig "items" list (lookup "v1" "ConfigMap" $ns "" | default dict)) -}}
{{- $p := index (.metadata.labels | default dict) "serving.platform/profile" | default "" -}}
{{- if $p }}{{ $avail = append $avail $p }}{{ end -}}
{{- end -}}
{{- fail (printf "endpoint %q: profile %q not found in namespace %q; available: [%s]. (Profiles are read from the cluster, so helm template / --dry-run=client can't render this chart.)" .name $name $ns (join ", " $avail)) -}}
{{- end -}}
{{- $spec := $specJson | fromJson -}}
{{- $scripts := lookup "v1" "ConfigMap" $ns "vllm-serve-script" | default dict -}}
{{- if not $scripts.data -}}
{{- fail (printf "vllm-serve-script ConfigMap not found in namespace %q - is the validate-serving-profiles release installed (terraform apply)?" $ns) -}}
{{- end -}}
{{- if and $ep.requirePrecompiled $spec.compileJob (not (include "serving.precompiled" (dict "root" $root "spec" $spec))) -}}
{{- fail (printf "endpoint %q: profile %q is not precompiled yet - compile Job %s has not completed (requirePrecompiled=true)" .name $name $spec.compileJob) -}}
{{- end -}}
{{- if and $ep.overrides (not $ep.allowOffProfile) -}}
{{- fail (printf "endpoint %q: overrides change the engine config away from the profile (forces a recompile); set allowOffProfile=true to proceed" .name) -}}
{{- end -}}
{{- if not (has $ep.engine (list "vllm" "ray")) -}}
{{- fail (printf "endpoint %q: engine must be vllm or ray, got %q" .name $ep.engine) -}}
{{- end -}}
{{- if and (eq $ep.engine "ray") (not $spec.rayImage) -}}
{{- fail (printf "endpoint %q: engine=ray needs a Neuron profile with a Ray image; profile %q is %s" .name $name ($spec.hardware | default "unknown")) -}}
{{- end -}}
{{- $env := deepCopy ($cm.data | default dict) -}}
{{- range $k, $v := ($ep.overrides | default dict) -}}
{{- $_ := set $env $k (toString $v) -}}
{{- end -}}
{{- dict "env" $env "spec" $spec "scripts" ($scripts.data | default dict) "offProfile" (not (empty $ep.overrides)) | toJson -}}
{{- end -}}

{{/* "true" if the profile's compile Job has completed. Pass { root, spec }. */}}
{{- define "serving.precompiled" -}}
{{- $ns := .root.Values.platformNamespace | default .root.Release.Namespace -}}
{{- $job := lookup "batch/v1" "Job" $ns (.spec.compileJob | default "") | default dict -}}
{{- if ge (int (dig "status" "succeeded" 0 $job)) 1 }}true{{ end -}}
{{- end -}}

{{/*
Init container: pull the model dir (weights + shared cache/) from S3 to node-local
NVMe. sync (CRT) reconciles against S3: warm NVMe -> transfers nothing, fresh
node -> full pull, partial -> just the gap. Pass { ctx, spec }.
*/}}
{{- define "serving.modelDownload" -}}
- name: model-download
  image: {{ .spec.awsCliImage }}
  command: ["/bin/bash", "-c"]
  envFrom:
    - configMapRef:
        name: {{ .ctx.name }}-env
  args:
    - |
      set -e
      # Model dir = weights + shared compile cache (cache/).
      aws configure set s3.preferred_transfer_client crt
      aws s3 sync "$S3_MODEL_URI/" "$MODEL_ID/"
      mkdir -p "$VLLM_CACHE_ROOT"
      # Precompiled for this profile + image? (marker written by its compile Job)
      if [ -n "${S3_CACHE_READY_URI:-}" ] && ! aws s3 ls "$S3_CACHE_READY_URI" >/dev/null 2>&1; then
        echo "WARNING: profile not precompiled yet ($S3_CACHE_READY_URI missing) - vLLM will compile at startup."
      fi
      # Runs as root; the serving container may not (e.g. Ray's `ray` user), and
      # vLLM writes lock files / new graphs into VLLM_CACHE_ROOT.
      chmod -R a+rwX "$MODEL_ID"
  volumeMounts:
    - name: local-storage
      mountPath: {{ .spec.modelsPath }}
{{- end -}}

{{/* Accelerator resources for the serving container. Pass <spec>. */}}
{{- define "serving.resources" -}}
{{- $res := .resources | default dict -}}
requests:
  {{- with $res.cpu }}
  cpu: {{ . | quote }}
  {{- end }}
  {{- with $res.memory }}
  memory: {{ . }}
  {{- end }}
  {{- with .deviceResource }}
  {{ . }}: {{ $.devices | quote }}
  {{- end }}
limits:
  {{- with $res.cpu }}
  cpu: {{ . | quote }}
  {{- end }}
  {{- with $res.memory }}
  memory: {{ . }}
  {{- end }}
  {{- with .deviceResource }}
  {{ . }}: {{ $.devices | quote }}
  {{- end }}
{{- end -}}
