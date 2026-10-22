# Ray Serve for the optional Ray path, on the same vLLM image as the vllm-neuron
# folder, so Ray and standalone vLLM run the identical vLLM build. Keep the two
# FROM lines in step.
FROM public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.29.0.1.2.0-neuronx-py314-sdk2.33.0-ubuntu26.04
LABEL hardware=neuron
USER root
# Needs a wheel for the DLC's Python (3.14) and a version the KubeRay operator
# supports (1.7.x: Ray 2.55/2.56).
RUN python3 -m pip install --no-cache-dir "ray[serve]==2.56.1"
# KubeRay runs Ray as the `ray` user; the Serve app is mounted into /home/ray/python.
RUN useradd -m -s /bin/bash ray && mkdir -p /home/ray/python && chown -R ray:ray /home/ray
USER ray
WORKDIR /home/ray
ENV PYTHONPATH="/opt/conda/lib/python3.14/site-packages:/home/ray/python:$PYTHONPATH"
# KubeRay sets the container command (ray start ...); drop vLLM's ENTRYPOINT.
ENTRYPOINT []
