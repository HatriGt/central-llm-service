# Fixes Needed for Production Deployment

## ✅ Docker Image ENTRYPOINT Issue (FIXED)

### Problem (Was):
The base image `vllm/vllm-openai:latest` has its own ENTRYPOINT set, causing our CMD to be appended incorrectly. This results in duplicate commands:
```
ENTRYPOINT: python3 -m vllm.entrypoints.openai.api_server
CMD: python3 -m vllm.entrypoints.openai.api_server --model ... (our args)
Result: python3 -m vllm.entrypoints.openai.api_server python3 -m vllm.entrypoints.openai.api_server --model ...
```

### Solution Applied:
Updated `docker/ecr-build/Dockerfile` to reset ENTRYPOINT:

```dockerfile
# Reset ENTRYPOINT from base image to avoid command duplication
ENTRYPOINT []

# Start the vLLM server
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", \
     "--model", "/app/models/Ministral-8B-Instruct-2410/", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--served-model-name", "ministral-8b-instruct", \
     "--max-model-len", "24576", \
     "--gpu-memory-utilization", "0.9", \
     "--trust-remote-code"]
```

### To Deploy This Fix:

#### Using AWS CodeBuild:
```bash
# 1. Commit the updated Dockerfile
git add docker/ecr-build/Dockerfile
git commit -m "Fix: Reset ENTRYPOINT to avoid command duplication"

# 2. Push to trigger CodeBuild (if auto-trigger configured)
git push origin main

# Or manually start build:
aws codebuild start-build \
  --project-name mistral8b-vllm-build \
  --region eu-central-1
```

#### Manual Build (Alternative):
```bash
cd docker/ecr-build
docker build -t mistral8b-vllm .
docker tag mistral8b-vllm:latest 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin 396360117331.dkr.ecr.eu-central-1.amazonaws.com
docker push 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
```

#### Update ECS Service:
```bash
# Register updated task definition (now uses Docker CMD properly)
aws ecs register-task-definition \
  --cli-input-json file://aws/ecs-task-definition.json \
  --region eu-central-1

# Update service to use new task definition
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --task-definition central-llm-service \
  --force-new-deployment \
  --region eu-central-1
```

**Status:** ✅ **FIXED** - Dockerfile and task definition updated. Ready to rebuild.

---

## 📋 Other Issues Fixed:

### ✅ Network Mode Issue
- **Problem:** awsvpc mode made API inaccessible via EC2 public IP
- **Fix:** Changed to bridge mode in task definition
- **Status:** FIXED

### ✅ Disk Space Issue  
- **Problem:** Default 30GB too small for 54.6GB Docker image
- **Fix:** Launch instances with 100GB EBS volume
- **Status:** FIXED

### ✅ GPU Access Issue
- **Problem:** Container couldn't access GPU in bridge mode
- **Fix:** Added GPU resource requirement to task definition
- **Status:** FIXED

### ✅ SSH Access Issue
- **Problem:** No SSH key for instance access
- **Fix:** Created key pair `central-llm-key.pem` and added port 22 to security group
- **Status:** FIXED

