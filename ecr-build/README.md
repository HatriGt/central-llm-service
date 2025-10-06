# ECR Build Directory

This directory contains only the essential files needed to build and push the Docker image to ECR.

## Files:
- `Dockerfile` - Docker build instructions
- `.dockerignore` - Excludes unnecessary files
- `models/` - Ministral 8B model files (~30GB)

## Build and Push Commands:

```bash
# Login to ECR
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin 396360117331.dkr.ecr.eu-central-1.amazonaws.com

# Build image
docker build -t mistral8b-vllm .

# Tag for ECR
docker tag mistral8b-vllm:latest 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest

# Push to ECR
docker push 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
```

## Prerequisites:
- AWS CLI configured with ECR permissions
- Docker installed and running
- ECR repository `mistral8b-vllm` exists in `eu-central-1`
