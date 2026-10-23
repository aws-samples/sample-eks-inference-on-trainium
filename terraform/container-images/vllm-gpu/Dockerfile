# vLLM CUDA image: the AWS vLLM Deep Learning Container (upstream vLLM v0.29.0
# plus EFA, on ECR Public). Keep its vLLM version in step with the Neuron images
# (vLLM 0.29.0) so GPU and Neuron results compare like for like.
FROM public.ecr.aws/deep-learning-containers/vllm:0.29.0-gpu-py312-cu130-ubuntu24.04-ec2-v1.3
LABEL hardware=gpu
# Tools the chart's bench mode needs that the Neuron DLC has and the vLLM DLC
# lacks: the AWS CLI (uploads the results to S3) and pandas (the sweep's
# summary.csv and the chart's summary table).
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends unzip \
 && curl -sSfo /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
 && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip /var/lib/apt/lists/* \
 && uv pip install --system --no-cache pandas \
 && aws --version && python3 -c 'import pandas, vllm'
