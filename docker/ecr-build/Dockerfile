# Use official vLLM Docker image with Llama 3.2 Vision support
# v0.6.2+ required for Llama 3.2 Vision support (released Sept 2024)
FROM vllm/vllm-openai:v0.6.6

# Set working directory
WORKDIR /app

# Install additional dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Copy audit proxy application
COPY app/ /app/app/

# Copy all model files at once (simpler approach)
COPY models/ /app/models/

# Set environment variables
ENV MODEL_PATH=/app/models/Llama-3.2-11B-Vision-Instruct/
ENV CUDA_VISIBLE_DEVICES=0
ENV PROXY_PORT=8000
ENV VLLM_PORT=8001

# Expose the port
EXPOSE 8000

# Health check (proxy exposes the health endpoint)
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Start the audit proxy which launches the vLLM server internally
ENTRYPOINT ["python3", "/app/app/audit_proxy.py"]