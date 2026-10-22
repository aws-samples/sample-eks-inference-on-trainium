# Ray Serve for the optional Ray path, on the same vLLM image as the vllm-gpu
# folder, so Ray and standalone vLLM run the identical vLLM build. Keep the two
# FROM lines in step.
FROM vllm/vllm-openai:v0.29.0
LABEL hardware=gpu
USER root
# vllm-openai installs with uv into the system Python (it may have no pip).
# Needs a version the KubeRay operator supports (1.7.x: Ray 2.55/2.56).
RUN uv pip install --system "ray[serve]==2.56.1"
# KubeRay runs Ray as the `ray` user; the Serve app is mounted into /home/ray/python.
RUN useradd -m -s /bin/bash ray && mkdir -p /home/ray/python && chown -R ray:ray /home/ray
USER ray
WORKDIR /home/ray
# KubeRay sets the container command (ray start ...); drop vLLM's ENTRYPOINT.
ENTRYPOINT []
