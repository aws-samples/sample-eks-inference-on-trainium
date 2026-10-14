"""Ray Serve app for vLLM on Neuron (trn2) or GPU (p5), mounted into the
RayService pods (ray-service-trn2.yaml / ray-service-p5.yaml) from the
vllm-ray-app ConfigMap.

The engine is configured from env vars set in the manifest - the same Step 1
values as the standalone vLLM deployment - and parsed by vLLM's own CLI parser,
so on Neuron the engine config (and the NEFF cache key) match the compile Job
and `vllm serve`.

We do NOT hand-roll the OpenAI response format. The deployment builds vLLM's own
serving objects (OpenAIServingChat / OpenAIServingCompletion /
OpenAIServingModels) via ``init_app_state`` - exactly what ``vllm serve`` does -
and the routes delegate to them: ``/v1/completions``, ``/v1/chat/completions``
(harmony reasoning split into ``reasoning`` vs ``content``), ``/v1/models``,
streaming.

Why not vLLM's ``build_app``: Ray Serve imports this module on the HEAD (x86, no
accelerator) to build the deployment graph, and vLLM's arg parser instantiates
``DeviceConfig``, which fails there. So all device-touching work (arg parsing,
engine build, init_app_state) happens in ``__init__`` on the accelerator worker.
"""
import logging
import os
from types import SimpleNamespace

from fastapi import FastAPI, Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from ray import serve

from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.entrypoints.openai.api_server import init_app_state
from vllm.entrypoints.openai.chat_completion.protocol import ChatCompletionRequest
from vllm.entrypoints.openai.cli_args import make_arg_parser
from vllm.entrypoints.openai.completion.protocol import CompletionRequest
from vllm.entrypoints.openai.engine.protocol import ErrorResponse
from vllm.usage.usage_lib import UsageContext
from vllm.utils.argparse_utils import FlexibleArgumentParser
from vllm.v1.engine.async_llm import AsyncLLM

logger = logging.getLogger("ray.serve")

MODEL = os.environ["MODEL_ID"]
# Accelerators each replica's actor claims on its worker: NeuronCores on trn2
# (custom resource advertised by the worker's rayStartParams), GPUs on p5.
if os.environ.get("NEURON_CORES"):
    RAY_ACTOR_OPTIONS = {"resources": {"neuron_cores": int(os.environ["NEURON_CORES"])}}
else:
    RAY_ACTOR_OPTIONS = {"num_gpus": int(os.environ.get("NUM_GPUS", "1"))}
NUM_REPLICAS = int(os.environ.get("NUM_REPLICAS", "1"))

# Empty at import (runs on the head too) - no device-touching calls here.
app = FastAPI()


def build_serve_args():
    """The same engine flags `vllm serve` gets in the standalone deployment.
    Called only from __init__ (on the worker); make_arg_parser touches DeviceConfig.
    """
    argv = [
        "--model", MODEL,
        "--tokenizer", MODEL,
        "--served-model-name", MODEL,
        f"--tensor-parallel-size={os.environ['TENSOR_PARALLEL_SIZE']}",
        f"--max-model-len={os.environ['MAX_MODEL_LEN']}",
        f"--max-num-seqs={os.environ['MAX_NUM_SEQS']}",
        f"--max-num-batched-tokens={os.environ['MAX_NUM_BATCHED_TOKENS']}",
        "--enable-prefix-caching",
        "--no-disable-hybrid-kv-cache-manager",
    ]
    # Hardware-specific flags, only when set (Step 1 table).
    for env, flag in [("HF_OVERRIDES", "--hf-overrides"), ("ADDITIONAL_CONFIG", "--additional-config"), ("DTYPE", "--dtype")]:
        if os.environ.get(env):
            argv.append(f"{flag}={os.environ[env]}")
    return make_arg_parser(FlexibleArgumentParser()).parse_args(argv)


@serve.deployment(
    name="vllm",
    num_replicas=NUM_REPLICAS,
    ray_actor_options=RAY_ACTOR_OPTIONS,
    health_check_period_s=10,
)
@serve.ingress(app)
class VLLMDeployment:
    async def __init__(self):
        if os.environ.get("NEURON_CORES"):
            # Ray sets NEURON_RT_VISIBLE_CORES for actors holding the neuron_cores
            # resource; vLLM's multiproc executor refuses to start with it preset.
            os.environ.pop("NEURON_RT_VISIBLE_CORES", None)

        args = build_serve_args()
        engine_args = AsyncEngineArgs.from_cli_args(args)
        vllm_config = engine_args.create_engine_config(usage_context=UsageContext.OPENAI_API_SERVER)
        engine = AsyncLLM.from_vllm_config(
            vllm_config=vllm_config, usage_context=UsageContext.OPENAI_API_SERVER
        )
        supported_tasks = await engine.get_supported_tasks()

        # init_app_state builds the same serving objects vllm serve uses and hangs
        # them off the passed-in state. We keep that state and delegate to it.
        self.state = SimpleNamespace()
        await init_app_state(engine, self.state, args, supported_tasks)
        logger.info("VLLMDeployment ready for %s (tasks=%s)", MODEL, supported_tasks)

    @app.get("/health")
    async def health(self):
        return Response(status_code=200)

    @app.get("/v1/models")
    async def show_models(self, raw_request: Request):
        models = await self.state.openai_serving_models.show_available_models()
        return JSONResponse(content=models.model_dump())

    @app.post("/v1/chat/completions")
    async def create_chat_completion(self, raw_request: Request):
        request = ChatCompletionRequest(**(await raw_request.json()))
        gen = await self.state.openai_serving_chat.create_chat_completion(request, raw_request)
        if isinstance(gen, ErrorResponse):
            return JSONResponse(content=gen.model_dump(), status_code=gen.error.code)
        if request.stream:
            return StreamingResponse(content=gen, media_type="text/event-stream")
        return JSONResponse(content=gen.model_dump())

    @app.post("/v1/completions")
    async def create_completion(self, raw_request: Request):
        request = CompletionRequest(**(await raw_request.json()))
        gen = await self.state.openai_serving_completion.create_completion(request, raw_request)
        if isinstance(gen, ErrorResponse):
            return JSONResponse(content=gen.model_dump(), status_code=gen.error.code)
        if request.stream:
            return StreamingResponse(content=gen, media_type="text/event-stream")
        return JSONResponse(content=gen.model_dump())


deployment = VLLMDeployment.bind()
