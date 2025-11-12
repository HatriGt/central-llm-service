# Running ECR Image Locally

This guide explains how to pull and run the Docker image from AWS ECR on your local machine.

## Prerequisites

- ✅ Docker installed and running
- ✅ AWS CLI configured with ECR access
- ✅ NVIDIA GPU (for optimal performance)
- ✅ NVIDIA Container Toolkit installed (for GPU support)

## Step 1: Login to ECR

```bash
# Login to AWS ECR
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin \
  396360117331.dkr.ecr.eu-central-1.amazonaws.com
```

**Expected output:**
```
Login Succeeded
```

## Step 2: Pull the Image from ECR

```bash
# Pull the image
docker pull 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest

# (Optional) Tag it with a shorter name for easier use
docker tag 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest mistral8b-vllm:local
```

## Step 3: Run the Image Locally

### Option A: With GPU (Recommended)

```bash
docker run -d \
  --name ministral-llm \
  --gpus all \
  -p 8000:8000 \
  -e CUDA_VISIBLE_DEVICES=0 \
  mistral8b-vllm:local
```

### Option B: With Specific GPU

```bash
docker run -d \
  --name ministral-llm \
  --gpus '"device=0"' \
  -p 8000:8000 \
  mistral8b-vllm:local
```

### Option C: CPU Only (Slow, not recommended)

```bash
docker run -d \
  --name ministral-llm \
  -p 8000:8000 \
  mistral8b-vllm:local
```

## Step 4: Check Container Status

```bash
# Check if container is running
docker ps

# View container logs
docker logs ministral-llm

# Follow logs in real-time
docker logs -f ministral-llm
```

## Step 5: Test the API

### Health Check
```bash
curl http://localhost:8000/health
```

### Chat Completion Request
```bash
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "messages": [
      {
        "role": "user",
        "content": "Hello! Can you tell me a short joke?"
      }
    ],
    "max_tokens": 100,
    "temperature": 0.7
  }'
```

### Text Completion Request
```bash
curl -X POST "http://localhost:8000/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "prompt": "The capital of France is",
    "max_tokens": 50
  }'
```

## Management Commands

### Stop the Container
```bash
docker stop ministral-llm
```

### Start the Container
```bash
docker start ministral-llm
```

### Remove the Container
```bash
docker stop ministral-llm
docker rm ministral-llm
```

### View Resource Usage
```bash
docker stats ministral-llm
```

## Test with Postman

**Endpoint:** `POST http://localhost:8000/v1/chat/completions`

**Headers:**
```
Content-Type: application/json
```

**Body:**
```json
{
  "model": "ministral-8b-instruct",
  "messages": [
    {
      "role": "user",
      "content": "Explain quantum computing in simple terms"
    }
  ],
  "max_tokens": 200,
  "temperature": 0.7
}
```

## Troubleshooting

### Issue: "Cannot connect to the Docker daemon"
**Solution:** Make sure Docker Desktop is running

### Issue: "GPU not available"
**Solution:** Install NVIDIA Container Toolkit:
```bash
# Ubuntu/Debian
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

### Issue: "Port 8000 already in use"
**Solution:** Use a different port:
```bash
docker run -d --name ministral-llm --gpus all -p 8080:8000 mistral8b-vllm:local
# Then access at http://localhost:8080
```

### Issue: "Out of memory"
**Solution:** The model requires ~24GB GPU memory. Use a GPU with sufficient memory or adjust settings.

## Quick Reference

| Command | Description |
|---------|-------------|
| `docker pull <ecr-image>` | Pull image from ECR |
| `docker run -d --gpus all -p 8000:8000 <image>` | Run with GPU |
| `docker logs -f <container>` | View logs |
| `docker stop <container>` | Stop container |
| `docker start <container>` | Start container |
| `docker rm <container>` | Remove container |
| `curl http://localhost:8000/health` | Health check |

## Performance Notes

- **GPU (Recommended):** ~50-100 tokens/second
- **CPU Only:** Very slow, not recommended for production
- **Memory:** ~24GB GPU memory required
- **Startup Time:** ~30-60 seconds for model loading

