"""Bootstrap-compile the model with vLLM's offline API.

Constructing ``LLM`` triggers the NxDI trace + neuronx-cc compile; the config is
read from env vars so it exactly matches the serving manifests (a mismatch would
force a recompile at serve time). Run by the model-compile-s3 Job on trn1.

The ``if __name__ == "__main__"`` guard is required: vLLM's v1 engine spawns
EngineCore child processes with the "spawn" start method, which re-imports this
module. Without the guard the children would re-run the compile and crash.
"""
import os
import sys

from vllm import LLM, SamplingParams


def main():
    llm = LLM(
        model=os.environ["MODEL_ID"],
        tensor_parallel_size=int(os.environ["TENSOR_PARALLEL_SIZE"]),
        max_num_seqs=int(os.environ["MAX_NUM_SEQS"]),
        max_model_len=int(os.environ["MAX_MODEL_LEN"]),
        dtype=os.environ["DTYPE"],
        enable_prefix_caching=False,  # Neuron scheduler has no block_size
    )

    out = llm.generate(["Hello, world!"], SamplingParams(max_tokens=8))
    print("Bootstrap inference:", out[0].outputs[0].text)
    print("Compiled artifacts written to:")
    print("NEURON_COMPILED_ARTIFACTS:", os.environ["NEURON_COMPILED_ARTIFACTS"])
    print("NEURON_COMPILE_CACHE_URL:", os.environ["NEURON_COMPILE_CACHE_URL"])

    # vLLM leaves engine subprocesses that hang a normal interpreter exit;
    # hard-exit so the container proceeds to the upload step and the Job completes.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
