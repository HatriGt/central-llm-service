#!/bin/bash
# Run vLLM container with volume mount for model files

# Create a temporary container with volume mount
docker run -d \
  --name llama32-vision-temp \
  --gpus all \
  -p 8000:8000 \
  -v $(pwd)/models:/app/models \
  vllm/vllm-openai:v0.5.4 \
  python3 -m vllm.entrypoints.openai.api_server \
  --model /app/models/Llama-3.2-11B-Vision-Instruct/ \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name llama-3.2-11b-vision-instruct \
  --max-model-len 50000 \
  --gpu-memory-utilization 0.9 \
  --trust-remote-code

echo "Container started with volume mount. Model files are mounted from host."
echo "Test with: curl http://localhost:8000/v1/chat/completions"
