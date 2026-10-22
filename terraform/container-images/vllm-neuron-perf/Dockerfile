# The stock DLC plus Jim Burtoft's GPT-OSS Trn2 performance branches, pinned to
# commits: the vLLM-Neuron 0.29 fork (gptoss-trn2-perf-0.29) and the NKI Library
# 2.33 kernels (gptoss-trn2-perf-2.33). --no-deps keeps the image's vLLM, torch
# and Neuron SDK packages.
FROM public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.29.0.1.2.0-neuronx-py314-sdk2.33.0-ubuntu26.04
LABEL hardware=neuron
RUN pip install --no-cache-dir --no-deps --force-reinstall \
      https://github.com/jimburtoft/vllm-neuron/archive/acf74ec9b1a5d7ac9a0ce40d9afa41d134de00b2.tar.gz \
 && SETUPTOOLS_SCM_PRETEND_VERSION=2.33.0 pip install --no-cache-dir --no-deps \
      https://github.com/jimburtoft/nki-library/archive/ab1a4a8fad5f418abda4d0cde516a48abd85f014.tar.gz \
 && python -c 'from nkilib.core.moe.moe_tkg import selective_expert_impl as m; assert m.SUPPORTS_GATE_UP_MAJOR'
