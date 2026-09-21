# =============================================================================
# RETIRED: FSx model pull job + fsx-inspector — replaced by the S3 pull job
# (see pull-to-s3.tf). Commented out on purpose: `terraform apply` will DELETE
# the model-download Job and fsx-inspector Pod. Kept for reference; depends on
# the (also-commented) fsx.tf resources, so both must stay commented together.
# =============================================================================

/*
# We use the kubectl provider here because:
# 1. Its one less provider and the kubectl provider is already in use elsewhere
# 2. The Kubernetes provider is problematic, wanting to reach out to the API server
#    quite earlier in the process and usually fails, plus it does not support retries
#    which the kubectl provider does (making it more resilient to transient issues)
# 3. Its easier to copy+paste the YAML body and deploy directly, outside of Terraform

################################################################################
# Download model from Mistral CDN into FSx file system
# This:
# 1. Avoids the need for dealing with HuggingFace API tokens
# 2. Pre-pulls the image during account provisioning which avoids this
#    time penalty during the workshop event
################################################################################

resource "kubectl_manifest" "job_model_download" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: model-download
    spec:
      backoffLimit: 1
      completionMode: NonIndexed
      completions: 1
      template:
        spec:
          containers:
            - name: pull
              image: public.ecr.aws/e3e2e5u9/neuron/genai:v6
              command:
                - python
              args:
                - -c
                - |
                  import os, time
                  from datetime import datetime, timezone
                  from huggingface_hub import snapshot_download

                  def ts():
                      return datetime.now(timezone.utc).strftime('%H:%M:%S')

                  t0 = time.time(); tp = t0
                  def step(msg):
                      global tp
                      now = time.time()
                      print(f'[{ts()}] step took {int(now-tp)}s | total {int(now-t0)}s | done: {msg}', flush=True)
                      tp = now

                  print(f'[{ts()}] START - FSx model download', flush=True)

                  # Download v0.3 instruct model from HF into the FSx mount
                  os.system('rm -rf /models/mistral-7b-v0.3')
                  os.makedirs('/models/mistral-7b-v0.3', exist_ok=True)
                  snapshot_download(repo_id='aws-neuron/Mistral-7B-Instruct-v0.3-seqlen-2048-bs-1-cores-2', local_dir='/models/mistral-7b-v0.3')
                  size = os.popen('du -sh /models/mistral-7b-v0.3 | cut -f1').read().strip()
                  step(f'HF download -> /models (FSx) ({size})')

                  os.system('chmod -R 755 /models/mistral-7b-v0.3')
                  step('chmod -R 755')

                  print(f'[{ts()}] DONE. Total {int(time.time()-t0)}s. Model cached at /models/mistral-7b-v0.3', flush=True)
              securityContext:
                allowPrivilegeEscalation: false
                runAsUser: 0
              volumeMounts:
                - name: persistent-storage
                  mountPath: /models
          nodeSelector:
            instanceType: mixed-x86
            provisionerType: Karpenter
          restartPolicy: Never
          volumes:
            - name: persistent-storage
              persistentVolumeClaim:
                claimName: ${local.volume_name}
  YAML
  depends_on = [
    kubectl_manifest.mixed-x86_nodepool,
    module.karpenter,
    kubectl_manifest.fsx_pvc
  ]
}


resource "kubectl_manifest" "fsx-inspector" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Pod
    metadata:
      name: fsx-inspector
      namespace: default
    spec:
      containers:
      - name: fsx-inspector
        image: ubuntu:20.04
        command: ["/bin/sh", "-c", "while true; do sleep 86400; done"]
        volumeMounts:
        - name: persistent-storage
          mountPath: /models
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
      volumes:
      - name: persistent-storage
        persistentVolumeClaim:
          claimName: fsx-models
      restartPolicy: Never
  YAML
  depends_on = [
    kubectl_manifest.job_model_download
  ]
}
*/
