#!/bin/bash
# Run vLLM container with volume mount for model files

# Create a temporary container with volume mount
docker run -d \
  --name mistral8b-temp \
  --gpus all \
  -p 8000:8000 \
  -v $(pwd)/models:/app/models \
  vllm/vllm-openai:latest \
  python3 -m vllm.entrypoints.openai.api_server \
  --model /app/models/Ministral-8B-Instruct-2410/ \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name ministral-8b-instruct \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.9 \
  --trust-remote-code

echo "Container started with volume mount. Model files are mounted from host."
echo "Test with: curl http://localhost:8000/v1/chat/completions"
