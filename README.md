# Central LLM Service - Ministral 8B with vLLM

This project provides a centralized LLM service using Ministral 8B model with vLLM, designed to be deployed on AWS ECS/EC2.

## Features

- **Ministral 8B Instruct Model**: High-performance 8B parameter model from Mistral AI
- **vLLM Integration**: Fast inference with vLLM 0.10.2
- **Docker Support**: Containerized deployment ready for AWS ECS
- **OpenAI Compatible API**: Standard chat completions and text completions endpoints
- **GPU Support**: NVIDIA CUDA acceleration

## Prerequisites

1. **NVIDIA GPU**: For optimal performance (recommended)
2. **Docker**: For containerization
3. **AWS Account**: For ECR and ECS deployment

## Setup

The Ministral 8B model is already downloaded and ready to use.

### Build Docker Image

```bash
docker build -t central-llm-service .
```

### Test Locally

```bash
# Start the server
docker-compose up

# In another terminal, test the API
python3 test_client.py
```

## API Usage

The server provides OpenAI-compatible endpoints:

### Chat Completions
```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "messages": [
      {"role": "user", "content": "Hello! How are you?"}
    ],
    "max_tokens": 100
  }'
```

### Text Completions
```bash
curl -X POST "http://localhost:8000/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "prompt": "The capital of France is",
    "max_tokens": 20
  }'
```

### Health Check
```bash
curl http://localhost:8000/health
```

## Configuration

### Environment Variables

- `CUDA_VISIBLE_DEVICES`: GPU device to use (default: 0)

### vLLM Parameters

The server is configured with:
- `--max-model-len 32768`: Maximum sequence length
- `--gpu-memory-utilization 0.9`: GPU memory usage
- `--tensor-parallel-size 1`: Tensor parallelism (adjust for multi-GPU)

## AWS Deployment

### 1. Push to ECR

```bash
# Tag and push to ECR
docker tag central-llm-service:latest <account-id>.dkr.ecr.<region>.amazonaws.com/central-llm-service:latest
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/central-llm-service:latest
```

### 2. ECS Task Definition

The container expects:
- **CPU**: 4+ vCPUs
- **Memory**: 16+ GB RAM
- **GPU**: 1x NVIDIA GPU (recommended)

### 3. Environment Variables

Set in ECS task definition:
- `CUDA_VISIBLE_DEVICES`: GPU device (usually 0)

## Performance

- **Model Size**: ~30GB
- **Memory Usage**: ~20-24GB with vLLM
- **Inference Speed**: ~50-100 tokens/second (depends on hardware)
- **Concurrent Requests**: Supports multiple concurrent requests

## Troubleshooting

### Common Issues

1. **Out of Memory**: Increase GPU memory or reduce `--gpu-memory-utilization`
2. **Model Not Found**: Ensure model is downloaded and path is correct
3. **GPU Not Available**: Ensure NVIDIA drivers and Docker GPU support

### Logs

Check container logs:
```bash
docker logs <container-id>
```

## Next Steps

1. Deploy to AWS ECS
2. Set up load balancing
3. Add monitoring and logging
4. Implement authentication
5. Add rate limiting

## License

This project uses the Ministral 8B model under the Mistral AI Research License.