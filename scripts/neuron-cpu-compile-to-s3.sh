#!/usr/bin/env bash
# Compile a model's Neuron graphs on a CPU-only host (VLLM_NEURON_CPU_COMPILE=1)
# and publish the NEFF cache to S3 with the AWS CLI CRT transfer client.
#
# Usage:
#   NEURON_PLATFORM_TARGET_OVERRIDE=trn2 \
#   ./neuron-cpu-compile-to-s3.sh s3://<bucket>/<prefix> \
#       --model openai/gpt-oss-20b --tensor-parallel-size 4 \
#       --max-model-len 8192 --max-num-seqs 8
#
# Everything after the S3 URI is passed to vLLM as engine args. They must match
# the serving command exactly (plus the same image / Neuron SDK, target and
# NEURON_LOGICAL_NC_CONFIG): all of them feed the per-graph cache key, and any
# drift turns every lookup into a miss.
#
# How the cache gets populated: building the engine runs vllm-neuron's warmup,
# which captures every prefill/decode graph and batch-compiles them with
# libtorch_neuronx_lite's parallel_compile(). That call promotes each compiled
# entry into NEURON_LIBTORCH_REMOTE_CACHE via save_cache(), so pointing it at a
# local staging dir and syncing that dir yields the remote-cache layout
# (<hash>/..., nki/...). Paths that bypass parallel_compile (native backend)
# don't promote, so any complete local entry left over is promoted afterwards.
#
# Consume on a Neuron host:
#   aws s3 sync s3://<bucket>/<prefix> /cache/neuron-remote
#   NEURON_LIBTORCH_REMOTE_CACHE=/cache/neuron-remote \
#   VLLM_NEURON_DISABLE_WARMUP_COMPILE=1 vllm serve <same engine args>
#
# Env:
#   NEURON_PLATFORM_TARGET_OVERRIDE  required, e.g. trn2 (no device to detect it)
#   NEURON_LIBTORCH_PARALLEL_COMPILE_WORKERS  neuronx-cc workers (default 8)
#   WORK_DIR                         local + staging cache dir (default: mktemp)
#   S3_TARGET_BANDWIDTH              CRT target_bandwidth, e.g. 50Gb/s (optional)
set -euo pipefail

if [[ $# -lt 2 || "$1" != s3://* ]]; then
  sed -n '2,10p' "$0" >&2
  exit 2
fi
S3_URI="${1%/}"
shift

: "${NEURON_PLATFORM_TARGET_OVERRIDE:?set to the serving instance family, e.g. trn2}"
if ! aws --version 2>&1 | grep -q '^aws-cli/2'; then
  echo "AWS CLI v2 is required for the CRT transfer client" >&2
  exit 1
fi

WORK_DIR="${WORK_DIR:-$(mktemp -d -t neuron-cpu-compile.XXXXXX)}"
mkdir -p "$WORK_DIR"

# Fresh local cache so every graph is compiled (and so promoted) by this run.
export VLLM_CACHE_ROOT="$WORK_DIR/local"
export NEURON_LIBTORCH_CACHE_ROOT="$WORK_DIR/local"
export NEURON_LIBTORCH_REMOTE_CACHE="$WORK_DIR/remote"
export VLLM_NEURON_CPU_COMPILE=1
export NEURON_LIBTORCH_PARALLEL_COMPILE_WORKERS="${NEURON_LIBTORCH_PARALLEL_COMPILE_WORKERS:-8}"
unset VLLM_NEURON_CPU_MODE  # mutually exclusive with CPU compile
mkdir -p "$NEURON_LIBTORCH_REMOTE_CACHE"

echo "==> Compiling for ${NEURON_PLATFORM_TARGET_OVERRIDE} (work dir: $WORK_DIR)"
python3 - "$@" <<'PY'
import dataclasses
import os
import re
import sys

from vllm import LLM
from vllm.engine.arg_utils import EngineArgs

try:
    from vllm.utils.argparse_utils import FlexibleArgumentParser
except ImportError:
    from vllm.utils import FlexibleArgumentParser

parser = EngineArgs.add_cli_args(FlexibleArgumentParser())
engine_args = EngineArgs.from_cli_args(parser.parse_args(sys.argv[1:]))

# Engine construction = graph capture + parallel compile + promotion. Nothing
# is executed in CPU-compile mode, so there's nothing to generate.
llm = LLM(**dataclasses.asdict(engine_args))
del llm

from libtorch_neuronx_lite import envs as libtorch_envs
from libtorch_neuronx_lite.compile.cache import save_cache

local = libtorch_envs.get_neuron_compile_cache_dir()
remote = os.environ["NEURON_LIBTORCH_REMOTE_CACHE"]

entries = sorted(
    d for d in os.listdir(local)
    if re.fullmatch(r"[0-9a-f]{32}", d) and os.path.isdir(os.path.join(local, d))
)
incomplete = []
for key in entries:
    try:
        save_cache(local, remote, key)  # no-op if already promoted
    except RuntimeError:
        incomplete.append(key)

print(f"==> {len(entries) - len(incomplete)} compiled graphs staged in {remote}")
if not entries:
    sys.exit("no compiled graphs found - did the engine reach warmup?")
if incomplete:
    sys.exit(f"incomplete cache entries (a serving run would miss these): {incomplete}")
PY

# CRT client via a throwaway config copy, so the user's ~/.aws/config is untouched.
ORIG_AWS_CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
export AWS_CONFIG_FILE="$WORK_DIR/aws-config"
if [[ -f "$ORIG_AWS_CONFIG" ]]; then cp "$ORIG_AWS_CONFIG" "$AWS_CONFIG_FILE"; else : >"$AWS_CONFIG_FILE"; fi
PROFILE="${AWS_PROFILE:-default}"
aws configure set s3.preferred_transfer_client crt --profile "$PROFILE"
if [[ -n "${S3_TARGET_BANDWIDTH:-}" ]]; then
  aws configure set s3.target_bandwidth "$S3_TARGET_BANDWIDTH" --profile "$PROFILE"
fi

echo "==> Uploading to $S3_URI"
# Lock files are ignored on fetch; staging dirs (*.tmp.*) only exist mid-promotion.
aws s3 sync "$NEURON_LIBTORCH_REMOTE_CACHE" "$S3_URI" \
  --no-progress --exclude "*.lock" --exclude "*.tmp.*"

echo "==> Done. Pull with: aws s3 sync $S3_URI <dir> && export NEURON_LIBTORCH_REMOTE_CACHE=<dir>"
