#!/bin/bash
# Shared vLLM launch command, vended by the serving-platform chart
# (vllm-serve-script ConfigMap). The compile Jobs and every vLLM serving pod run
# it; every flag comes from the serving profile env (vllm-profile-<name>
# ConfigMap), so compile and serve run the identical engine config and the NEFF
# cache keys match.
#
# The Ray path (vllm_ray_app.py, same ConfigMap) builds the same argv in Python -
# keep the fixed flags below in sync with it.
set -euo pipefail

args=(
  --tokenizer "$MODEL_ID"
  --host 0.0.0.0 --port "${PORT:-8000}"
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --max-num-seqs "$MAX_NUM_SEQS"
  --enable-prefix-caching
  --no-disable-hybrid-kv-cache-manager
)
if [ -n "${HF_OVERRIDES:-}" ]; then args+=(--hf-overrides "$HF_OVERRIDES"); fi
if [ -n "${ADDITIONAL_CONFIG:-}" ]; then args+=(--additional-config "$ADDITIONAL_CONFIG"); fi

exec vllm serve "$MODEL_ID" "${args[@]}"
