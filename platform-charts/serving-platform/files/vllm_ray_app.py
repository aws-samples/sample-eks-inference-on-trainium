"""Ray Serve app for vLLM on Neuron via the standalone vLLM Neuron plugin.

Vended by the serving-platform chart (vllm-serve-script ConfigMap) and mounted
into RayService pods by the serving chart. Model + engine config come from the
serving profile env, so the engine matches the profile's precompiled NEFFs.

We do NOT hand-roll the OpenAI response format. Instead the deployment builds
vLLM's own serving objects (OpenAIServingChat / OpenAIServingCompletion /
OpenAIServingModels) via ``init_app_state`` — exactly what ``vllm serve`` does —
and the route methods delegate to them. That gives full parity with the standalone
vLLM path: ``/v1/completions``, ``/v1/chat/completions`` (with harmony reasoning
split into ``reasoning`` vs ``content``), ``/v1/models``, and streaming.

Why delegation instead of vLLM's ``build_app``: Ray Serve imports this module on
the HEAD (x86, no accelerator) to build the deployment graph. vLLM's
``make_arg_parser``/``build_app`` instantiate ``DeviceConfig`` (device inference),
which fails on the head. So all device-touching work (arg parsing, engine build,
init_app_state) happens in ``__init__``, which runs on the Neuron worker. The
FastAPI app at import is empty; routes are plain methods referencing serving
objects built in ``__init__``.
"""
import os
import logging
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
neuron_cores = int(os.environ["NEURON_CORES"])

# Empty at import (runs on the head too) - no device-touching calls here.
app = FastAPI()


def build_serve_args():
    """Parse the same serve flags the compile Job / standalone deploy use, through
    vLLM's own CLI parser, so the engine config (and NEFF cache key) match exactly.
    Mirrors vllm-serve.sh (same ConfigMap); values come from the serving profile env
    (vllm-profile-<name> ConfigMap). Called only from __init__ (on the worker);
    make_arg_parser touches DeviceConfig.
    """
    parser = make_arg_parser(FlexibleArgumentParser())
    argv = [
        "--model", MODEL,
        "--served-model-name", MODEL,
        "--tensor-parallel-size", os.environ["TENSOR_PARALLEL_SIZE"],
        "--max-model-len", os.environ["MAX_MODEL_LEN"],
        "--max-num-batched-tokens", os.environ["MAX_NUM_BATCHED_TOKENS"],
        "--max-num-seqs", os.environ["MAX_NUM_SEQS"],
        "--enable-prefix-caching",
        "--no-disable-hybrid-kv-cache-manager",
    ]
    # Optional JSON flags, passed only when the profile sets them.
    if os.environ.get("HF_OVERRIDES"):
        argv += ["--hf-overrides", os.environ["HF_OVERRIDES"]]
    if os.environ.get("ADDITIONAL_CONFIG"):
        argv += ["--additional-config", os.environ["ADDITIONAL_CONFIG"]]
    return parser.parse_args(argv)


@serve.deployment(
    name="vllm",
    autoscaling_config={"min_replicas": 1, "max_replicas": 1},
    ray_actor_options={"resources": {"neuron_cores": neuron_cores}},
    health_check_period_s=10,
)
@serve.ingress(app)
class VLLMDeployment:
    async def __init__(self):
        # Ray auto-sets NEURON_RT_VISIBLE_CORES for actors holding the neuron_cores
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
