FROM python:3.12-slim

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    libssl-dev curl && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ai-dynamo==1.0.0 \
    scikit-learn scipy pandas numpy \
    aiohttp filterpy matplotlib pmdarima \
    prometheus-api-client prometheus-client \
    prophet pydantic kubernetes pyyaml

WORKDIR /workspace
COPY profiling_results /workspace/tests/planner/profiling_results

ENV PYTHONUNBUFFERED=1
