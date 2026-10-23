# Ray Serve for the optional Ray path, on the same vLLM image as the vllm-gpu
# folder, so Ray and standalone vLLM run the identical vLLM build. Keep the two
# FROM lines in step.
FROM public.ecr.aws/deep-learning-containers/vllm:0.29.0-gpu-py312-cu130-ubuntu24.04-ec2-v1.3
LABEL hardware=gpu
USER root
# The vLLM DLC installs vLLM with uv into the system Python (it may have no
# pip), which its apt upgrade marks externally managed: install next to vLLM
# anyway. Needs a version the KubeRay operator supports (1.7.x: Ray 2.55/2.56).
RUN uv pip install --system --break-system-packages "ray[serve]==2.56.1"
# KubeRay's default readiness probes call wget, which the vLLM DLC doesn't ship.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends wget \
 && rm -rf /var/lib/apt/lists/*
# KubeRay runs Ray as the `ray` user; the Serve app is mounted into /home/ray/python.
RUN useradd -m -s /bin/bash ray && mkdir -p /home/ray/python && chown -R ray:ray /home/ray
USER ray
WORKDIR /home/ray
# KubeRay sets the container command (ray start ...); drop the DLC's ENTRYPOINT.
ENTRYPOINT []
