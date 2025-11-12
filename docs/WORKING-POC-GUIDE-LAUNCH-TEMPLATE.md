# Working POC Guide (Launch Template Edition) - vLLM on AWS ECS with GPU

This variant of the POC guide uses the launch template `central-llm-launch-template`, backed by AMI `ami-0ea47fea769e59918`, so the g6e.2xlarge host boots with the vLLM Docker layers already cached. You no longer need to wait 3–5 minutes for the image pull each time.

---

## Overview

**What this POC does:**
- Deploys a vLLM inference server for `Ministral-8B-Instruct-2410`
- Runs on AWS ECS (EC2 launch type) with a pre-baked GPU AMI
- Exposes an OpenAI-compatible API endpoint on port 8000
- Supports 32,768 token context length

**Cost:** Same as the original guide (~$1.31/hour when the g6e.2xlarge is running plus ECR + snapshot storage when idle). Confirm current pricing before every launch.

---

## Prerequisites

1. AWS CLI configured with appropriate credentials.
2. Docker image `mistral8b-vllm:latest` already pushed to ECR (unchanged).
3. IAM roles: `ecsTaskExecutionRole`, `ecsTaskRole`, `ecsInstanceRole`.
4. SSH key pair: `central-llm-key.pem`.
5. Security group: `sg-01348191cf1b4bc37` (port 8000/22). Update if yours differs.
6. Launch template `central-llm-launch-template` pointing at AMI `ami-0ea47fea769e59918`. See `docs/SNAPSHOT-AMI-LAUNCH-TEMPLATE.md` if you need to rebuild it.

---

## Step-by-Step Deployment

### Step 1: Launch EC2 via the launch template

**Purpose:** Start the GPU instance that already contains the vLLM layers.

```bash
aws ec2 run-instances \
  --region eu-central-1 \
  --launch-template LaunchTemplateName=central-llm-launch-template \
  --count 1
```

**What this does:**
- Uses AMI `ami-0ea47fea769e59918` (registered from your cached snapshot).
- Bootstraps ECS agent with GPU support via user data.
- Requests a g6e.2xlarge with the standard 100 GB gp3 root volume.

**Wait time:** ~90 seconds (instance boot only; Docker layers already present).

Retrieve the instance ID for later:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" "Name=instance-state-name,Values=running" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId'
```

---

### Step 2: Start ECS service

**Purpose:** Bring up the vLLM task on the new instance.

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

With the cached image, expect:
- Docker pull: <60 seconds (layer verification only)
- Model load: ~2–3 minutes
- Health checks: ~2 minutes

Monitor status:

```bash
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output table
```

---

### Step 3: Fetch Public IP

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" "Name=instance-state-name,Values=running" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

### Step 4: Verify API

Same `curl` check as the original POC:

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

---

## Operational Notes

- **Logs:** Continue to use CloudWatch group `/ecs/central-llm-service` or `scripts/tail-vllm-logs.sh`.
- **Security hardening:** Front the instance with API Gateway + VPC link as outlined in the updated production plan.
- **Snapshot refresh:** When the container image changes, follow `docs/SNAPSHOT-AMI-LAUNCH-TEMPLATE.md` to capture a new snapshot/AMI and set it as the latest launch template version.

---

## Shutdown Procedure

### Step 1: Scale service to zero

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 0 \
  --region eu-central-1

aws ecs wait services-stable \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1
```

### Step 2: Terminate the instance

```bash
aws ec2 terminate-instances \
  --instance-ids <INSTANCE_ID> \
  --region eu-central-1

aws ec2 wait instance-terminated \
  --instance-ids <INSTANCE_ID> \
  --region eu-central-1
```

Because the launch template sets `DeleteOnTermination=true`, the 100 GB gp3 volume is removed automatically. Only the snapshot and ECR image remain on the bill.

### Step 3: Confirm shutdown

```bash
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{Desired:desiredCount,Running:runningCount}'

aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,pending" \
  --region eu-central-1
```

---

## Troubleshooting

All troubleshooting steps from `docs/WORKING-POC-GUIDE.md` remain valid. The only differences:

- If a task still pulls layers for several minutes, confirm that the launch template references the latest AMI (`aws ec2 describe-launch-template-versions`).
- After refreshing the snapshot/AMI, bump the launch template version and use the new default.

---

## Version History

- **2025-11-08:** Initial launch template edition (AMI `ami-0ea47fea769e59918`, snapshot `snap-04d5095fae1bfaca0`).


