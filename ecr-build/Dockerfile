# Use official vLLM Docker image as base
FROM vllm/vllm-openai:latest

# Set working directory
WORKDIR /app

# Copy all model files at once (simpler approach)
COPY models/ /app/models/

# Set environment variables
ENV MODEL_PATH=/app/models/Ministral-8B-Instruct-2410/
ENV CUDA_VISIBLE_DEVICES=0

# Expose the port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Start the vLLM server
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", \
     "--model", "/app/models/Ministral-8B-Instruct-2410/", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--served-model-name", "ministral-8b-instruct", \
     "--max-model-len", "32768", \
     "--gpu-memory-utilization", "0.9", \
     "--trust-remote-code"]