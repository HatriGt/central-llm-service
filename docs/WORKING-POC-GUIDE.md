# Working POC Guide - vLLM on AWS ECS with GPU

This document provides a complete, tested guide for deploying the Ministral-8B model using vLLM on AWS ECS with GPU support.

## Overview

**What this POC does:**
- Deploys a vLLM inference server for Ministral-8B-Instruct-2410
- Runs on AWS ECS with EC2 launch type
- Uses GPU instances (g6e.2xlarge with L40S GPU)
- Exposes an OpenAI-compatible API endpoint
- Supports full 32,768 token context length

**Cost:** ~$1.31/hour when running + ~$3.75/month ECR storage

---

## Prerequisites

1. **AWS CLI configured** with appropriate credentials
2. **Docker image built and pushed to ECR** (`mistral8b-vllm:latest`)
3. **SSH key pair created** (`central-llm-key.pem`)
4. **IAM roles configured:**
   - `ecsTaskExecutionRole`
   - `ecsTaskRole`
   - `ecsInstanceRole`
5. **Security group created** with ports 8000 (API) and 22 (SSH) open

---

## Step-by-Step Deployment

### Step 1: Launch EC2 Instance with GPU

**Purpose:** Create a GPU-enabled EC2 instance that will join the ECS cluster and run the vLLM container.

```bash
aws ec2 run-instances \
  --image-id ami-0e0b995e4bdf1a25d \
  --instance-type g6e.2xlarge \
  --key-name central-llm-key \
  --security-group-ids sg-01348191cf1b4bc37 \
  --iam-instance-profile Name=ecsInstanceRole \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=central-llm-ec2}]' \
  --user-data '#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config' \
  --region eu-central-1
```

**What this does:**
- `--image-id`: Uses ECS-optimized Amazon Linux 2 AMI with GPU drivers
- `--instance-type g6e.2xlarge`: GPU instance with 1x L40S (48GB VRAM), 8 vCPUs, 32GB RAM
- `--key-name`: Attaches SSH key for debugging access
- `--security-group-ids`: Allows inbound traffic on ports 8000 and 22
- `--iam-instance-profile`: Grants permissions for ECS agent to pull images and register with cluster
- `--block-device-mappings`: 100GB EBS volume (needed for large Docker image ~54GB)
- `--user-data`: Configures instance to join ECS cluster with GPU support enabled

**Wait time:** 2-3 minutes for instance to start

---

### Step 2: Start ECS Service

**Purpose:** Tell ECS to run 1 task (container) on the newly launched instance.

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

**What this does:**
- `--desired-count 1`: Requests ECS to maintain 1 running task
- ECS will pull the Docker image from ECR
- Container will start loading the model into GPU memory
- Health checks will begin after container starts

**Wait time:** 5-10 minutes for:
- Docker image pull (~3-5 min)
- Model loading (~2-3 min)
- Health checks to pass (~2 min)

---

### Step 3: Get Public IP Address

**Purpose:** Retrieve the public IP to access the API endpoint.

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

**What this does:**
- Filters instances by the `Name` tag
- Extracts only the public IP address
- Returns a single IP string (e.g., `35.158.160.40`)

---

### Step 4: Monitor Service Status

**Purpose:** Check if the ECS task is running and healthy.

```bash
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output table
```

**What this does:**
- Shows current task counts:
  - `Desired`: How many tasks ECS should maintain
  - `Running`: How many tasks are healthy and running
  - `Pending`: How many tasks are starting up

**Expected output when ready:**
```
---------------------------------
|      DescribeServices         |
+---------+-----------+---------+
| Desired |  Pending  | Running |
+---------+-----------+---------+
|  1      |  0        |  1      |
+---------+-----------+---------+
```

---

### Step 5: SSH into Instance (Optional - for debugging)

**Purpose:** Access the EC2 instance to view Docker logs and debug issues.

```bash
ssh -i central-llm-key.pem ec2-user@<PUBLIC_IP>
```

**Useful commands once inside:**
```bash
# View running containers
docker ps -a

# Tail container logs
docker logs -f <CONTAINER_ID>

# Check GPU status
nvidia-smi
```

**Or use the helper script:**
```bash
./scripts/tail-vllm-logs.sh
```

---

### Step 6: Test API Endpoint

**Purpose:** Verify the vLLM server is responding correctly.

```bash
curl -X POST http://<PUBLIC_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "messages": [{"role": "user", "content": "Say hello in one sentence!"}],
    "max_tokens": 50,
    "temperature": 0.7
  }'
```

**Expected response:**
```json
{
  "id": "cmpl-...",
  "object": "chat.completion",
  "created": 1699123456,
  "model": "ministral-8b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! It's great to connect with you today."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 12,
    "total_tokens": 27
  }
}
```

---

## Shutdown Procedure

**Always shut down resources when not in use to avoid unnecessary costs!**

### Step 1: Stop ECS Service

**Purpose:** Stop all running tasks.

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 0 \
  --region eu-central-1
```

**What this does:**
- Sets desired count to 0
- ECS will gracefully stop all running tasks
- Containers will be terminated

---

### Step 2: Terminate EC2 Instance

**Purpose:** Stop the GPU instance to avoid hourly charges.

```bash
# First, get the instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text

# Then terminate it
aws ec2 terminate-instances \
  --instance-ids <INSTANCE_ID> \
  --region eu-central-1
```

**What this does:**
- Permanently terminates the instance
- EBS volume is deleted (due to `DeleteOnTermination:true`)
- Instance cannot be restarted (must launch a new one)

---

### Step 3: Verify Shutdown

**Purpose:** Confirm no resources are running.

```bash
# Check ECS service
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{Desired:desiredCount,Running:runningCount}' \
  --output table

# Check EC2 instances
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,pending" \
  --region eu-central-1 \
  --query 'Reservations[*].Instances[*].{Instance:InstanceId,State:State.Name}' \
  --output table
```

**Expected output:**
- ECS: `Desired: 0, Running: 0`
- EC2: Empty table (no running instances)

---

## Troubleshooting

### Issue: Instance capacity errors

**Error message:**
```
InsufficientInstanceCapacity: We currently do not have sufficient g6e.2xlarge capacity
```

**Solutions:**
1. **Try without specifying subnet** (let AWS choose the AZ):
   ```bash
   # Remove --subnet-id from the run-instances command
   ```

2. **Try different availability zones:**
   ```bash
   # Check which AZs have capacity
   aws ec2 describe-instance-type-offerings \
     --location-type availability-zone \
     --filters "Name=instance-type,Values=g6e.2xlarge" \
     --region eu-central-1
   
   # Get subnet IDs for specific AZ
   aws ec2 describe-subnets \
     --filters "Name=availability-zone,Values=eu-central-1a" \
     --region eu-central-1 \
     --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone}'
   
   # Then add --subnet-id to run-instances command
   ```

3. **Try different instance type:**
   - `g6.4xlarge` - More expensive but better availability
   - `g5.2xlarge` - Older generation, better availability (requires reducing max-model-len to 24576)

---

### Issue: Container keeps restarting with exit code 1

**Check the logs:**
```bash
ssh -i central-llm-key.pem ec2-user@<PUBLIC_IP>
docker ps -a
docker logs <CONTAINER_ID>
```

**Common causes:**

1. **Insufficient GPU memory:**
   ```
   ValueError: ... 4.50 GiB KV cache needed > 4.31 GiB available
   ```
   **Solution:** Use g6e.2xlarge (not g6.4xlarge) or reduce `max-model-len` in task definition

2. **Image pull errors:**
   ```
   CannotPullContainerError
   ```
   **Solution:** Check ECR permissions in `ecsTaskExecutionRole`

3. **GPU not available:**
   ```
   RuntimeError: No CUDA GPUs are available
   ```
   **Solution:** Verify `ECS_ENABLE_GPU_SUPPORT=true` in user-data

---

### Issue: Task stuck in PENDING

**Check ECS events:**
```bash
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].events[:5]'
```

**Common causes:**
- Instance not yet registered with cluster (wait 2-3 min)
- Insufficient resources (CPU/memory/GPU)
- Image pull in progress (wait 3-5 min)

---

### Issue: API not responding

**Check container health:**
```bash
docker ps  # Look for "healthy" status
curl http://localhost:8000/health  # From inside the instance
```

**Common causes:**
- Container still starting (wait for "healthy" status)
- Health check failing (check logs)
- Security group not allowing port 8000
- Wrong public IP (instance was replaced)

---

## Cost Breakdown

### Hourly Costs (when running)
- **g6e.2xlarge instance:** $1.31/hour
- **EBS storage (100GB gp3):** ~$0.01/hour
- **Data transfer:** Minimal for testing
- **Total:** ~$1.32/hour

### Monthly Costs (when stopped)
- **ECR storage (~30GB):** ~$3.75/month
- **CloudWatch logs:** ~$0.50/month (minimal)
- **Total:** ~$4.25/month

### Example Usage Costs
- **1 hour test:** ~$1.32
- **8 hours/day for 1 week:** ~$73.92
- **24/7 for 1 month:** ~$950.40

**💡 Always shut down when not in use!**

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                         AWS Cloud                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    ECS Cluster                          │ │
│  │                                                          │ │
│  │  ┌──────────────────────────────────────────────────┐  │ │
│  │  │         EC2 Instance (g6e.2xlarge)               │  │ │
│  │  │                                                   │  │ │
│  │  │  ┌─────────────────────────────────────────┐    │  │ │
│  │  │  │    Docker Container (vLLM)              │    │  │ │
│  │  │  │                                          │    │  │ │
│  │  │  │  - Ministral-8B model                   │    │  │ │
│  │  │  │  - OpenAI-compatible API                │    │  │ │
│  │  │  │  - Port 8000                            │    │  │ │
│  │  │  │  - GPU: L40S (48GB VRAM)                │    │  │ │
│  │  │  └─────────────────────────────────────────┘    │  │ │
│  │  │                                                   │  │ │
│  │  └──────────────────────────────────────────────────┘  │ │
│  │                                                          │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    ECR Repository                       │ │
│  │              mistral8b-vllm:latest (~54GB)             │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTPS (Port 8000)
                            ▼
                    ┌──────────────┐
                    │   Client     │
                    │  (Postman)   │
                    └──────────────┘
```

---

## Key Configuration Files

### Task Definition
- **Location:** `aws/ecs-task-definition.json`
- **Key settings:**
  - `networkMode: "bridge"` - Allows direct access via EC2 public IP
  - `resourceRequirements: [{"type": "GPU", "value": "1"}]` - Requests 1 GPU
  - No `entryPoint` or `command` overrides - Uses Dockerfile's CMD directly

### Service Definition
- **Location:** `aws/ecs-service-definition.json`
- **Key settings:**
  - `launchType: "EC2"` - Uses EC2 instances (not Fargate)
  - `desiredCount: 1` - Maintains 1 running task

### Dockerfile
- **Location:** `docker/ecr-build/Dockerfile`
- **Key settings:**
  - `--max-model-len 32768` - Full context length
  - `--gpu-memory-utilization 0.9` - Uses 90% of GPU memory
  - `ENTRYPOINT []` - Resets base image entrypoint

---

## Helper Scripts

### Tail vLLM Logs
**Location:** `scripts/tail-vllm-logs.sh`

Automatically SSH into the instance and follow container logs:
```bash
./scripts/tail-vllm-logs.sh
```

---

## Next Steps

1. **Production deployment:**
   - Set up Application Load Balancer
   - Configure auto-scaling
   - Add monitoring and alerting
   - Implement proper authentication

2. **Cost optimization:**
   - Use Spot instances for non-critical workloads
   - Schedule instances to run only during business hours
   - Consider Reserved Instances for long-term use

3. **Performance tuning:**
   - Experiment with `--gpu-memory-utilization`
   - Test different batch sizes
   - Profile inference latency

---

## Support

For issues or questions:
1. Check CloudWatch logs: `/ecs/central-llm-service`
2. SSH into instance and check Docker logs
3. Review ECS service events
4. Consult the main deployment runbook: `docs/COMPLETE-DEPLOYMENT-RUNBOOK.md`

---

**Last updated:** November 7, 2024  
**Tested with:** g6e.2xlarge, Ministral-8B-Instruct-2410, vLLM 0.11.0
