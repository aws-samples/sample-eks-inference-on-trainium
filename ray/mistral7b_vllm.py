"""Ray Serve app for Mistral-7B on Neuron via vLLM.

Uses only vLLM classes present in the Neuron build (AsyncLLMEngine, SamplingParams)
and hand-writes a minimal OpenAI-compatible HTTP layer.

Config comes from env vars, matching the compile job and the head/worker containers.
"""
import os
import time
import uuid
import logging

from fastapi import FastAPI
from starlette.requests import Request
from starlette.responses import JSONResponse
from ray import serve
from transformers import AutoTokenizer
from vllm import SamplingParams
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.engine.async_llm_engine import AsyncLLMEngine

logger = logging.getLogger("ray.serve")
app = FastAPI()

neuron_cores = int(os.getenv("NEURON_CORES", "2"))


@serve.deployment(
    name="mistral7b-vllm-deployment",
    autoscaling_config={"min_replicas": 1, "max_replicas": 4},
    ray_actor_options={"resources": {"neuron_cores": neuron_cores}},
    health_check_period_s=10,
)
@serve.ingress(app)
class VLLMDeployment:
    def __init__(self, model, tensor_parallel_size, max_num_seqs, max_model_len, dtype):
        self.model = model
        engine_args = AsyncEngineArgs(
            model=model,
            tensor_parallel_size=tensor_parallel_size,
            max_num_seqs=max_num_seqs,
            max_model_len=max_model_len,
            dtype=dtype,
            enable_prefix_caching=False,  # Neuron scheduler has no block_size
        )
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)
        # Tokenizer drives the chat template (the model dir ships tokenizer files).
        self.tokenizer = AutoTokenizer.from_pretrained(model)
        logger.info("VLLMDeployment initialized for %s", model)

    @app.get("/v1/models")
    async def list_models(self):
        return {"object": "list", "data": [{"id": self.model, "object": "model", "owned_by": "local"}]}

    @app.post("/v1/chat/completions")
    async def chat_completions(self, request: Request):
        body = await request.json()
        # Tokenize the chat template to IDs and pass them straight to the engine.
        # (Passing the templated *string* would make vLLM re-tokenize and add a
        # second BOS on top of the template's <s>, which makes Mistral degenerate
        # into [INST] loops.)
        prompt_token_ids = self.tokenizer.apply_chat_template(
            body["messages"], add_generation_prompt=True
        )
        sampling = SamplingParams(
            temperature=body.get("temperature", 0.0),
            top_p=body.get("top_p", 1.0),
            max_tokens=body.get("max_tokens", 256),
            stop=body.get("stop"),
        )
        request_id = f"chatcmpl-{uuid.uuid4().hex}"

        # Drain the async generator; keep the last (complete) output.
        final = None
        async for out in self.engine.generate(
            {"prompt_token_ids": prompt_token_ids}, sampling, request_id
        ):
            final = out
        completion = final.outputs[0]

        return JSONResponse({
            "id": request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": completion.text},
                "finish_reason": completion.finish_reason,
            }],
        })


deployment = VLLMDeployment.bind(
    model=os.environ.get("MODEL_ID", "/tmp/models/mistral-7b-v0.3"),
    tensor_parallel_size=int(os.environ.get("TENSOR_PARALLEL_SIZE", "2")),
    max_num_seqs=int(os.environ.get("MAX_NUM_SEQS", "4")),
    max_model_len=int(os.environ.get("MAX_MODEL_LEN", "2048")),
    dtype=os.environ.get("DTYPE", "bfloat16"),
)
