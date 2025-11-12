# Complete Deployment Runbook - Ministral-8B on AWS ECS

This guide provides step-by-step instructions to deploy the Ministral-8B-Instruct model with vLLM on AWS ECS from scratch.

---

## 📋 Prerequisites

- AWS CLI installed and configured with credentials
- Docker image already pushed to ECR: `396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest`
- AWS Region: `eu-central-1`
- Sufficient IAM permissions (see `aws/iam-policies-required.json`)

---

## 🚀 Step-by-Step Deployment

### **Step 1: Create IAM Roles for ECS** (FREE - 5 minutes)

These roles allow ECS tasks to pull images from ECR, write logs, and EC2 instances to join the cluster.

#### 1.1 Create ECS Task Execution Role
**What it does:** Allows ECS to pull Docker images from ECR and write logs to CloudWatch

```bash
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --region eu-central-1
```

#### 1.2 Attach Policy to Task Execution Role
**What it does:** Grants permissions to pull ECR images and write CloudWatch logs

```bash
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
  --region eu-central-1
```

#### 1.3 Create ECS Task Role
**What it does:** Allows running containers to access AWS services (currently none, but required for task definition)

```bash
aws iam create-role \
  --role-name ecsTaskRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --region eu-central-1
```

#### 1.4 Create EC2 Instance Role for ECS
**What it does:** Allows EC2 instances to register with ECS cluster and run containers

```bash
aws iam create-role \
  --role-name ecsInstanceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --region eu-central-1
```

#### 1.5 Attach Policy to Instance Role
**What it does:** Grants EC2 instances permissions to communicate with ECS

```bash
aws iam attach-role-policy \
  --role-name ecsInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role \
  --region eu-central-1
```

#### 1.6 Create Instance Profile
**What it does:** Creates a container for the IAM role that can be attached to EC2 instances

```bash
aws iam create-instance-profile \
  --instance-profile-name ecsInstanceRole \
  --region eu-central-1
```

#### 1.7 Add Role to Instance Profile
**What it does:** Links the IAM role to the instance profile

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name ecsInstanceRole \
  --role-name ecsInstanceRole \
  --region eu-central-1
```

---

### **Step 2: Create ECS Cluster** (FREE - 1 minute)

**What it does:** Creates a logical grouping for your ECS tasks and services

```bash
aws ecs create-cluster \
  --cluster-name central-llm-service-cluster \
  --region eu-central-1
```

---

### **Step 3: Create Security Group** (FREE - 2 minutes)

#### 3.1 Create Security Group
**What it does:** Creates a firewall for your EC2 instance

```bash
aws ec2 create-security-group \
  --group-name central-llm-sg \
  --description "Security group for Ministral LLM service" \
  --region eu-central-1
```

**Output:** Note the `GroupId` (e.g., `sg-xxxxx`)

#### 3.2 Add Inbound Rule for API (Port 8000)
**What it does:** Allows public HTTP access to the vLLM API on port 8000

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0 \
  --region eu-central-1
```

#### 3.3 Add Inbound Rule for SSH (Port 22)
**What it does:** Allows SSH access for debugging and management

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region eu-central-1
```

---

### **Step 4: Create SSH Key Pair** (FREE - 1 minute)

**What it does:** Creates an SSH key pair for secure access to EC2 instance

```bash
aws ec2 create-key-pair \
  --key-name central-llm-key \
  --region eu-central-1 \
  --query 'KeyMaterial' \
  --output text > central-llm-key.pem

chmod 400 central-llm-key.pem
```

---

### **Step 5: Create CloudWatch Log Group** (FREE - 1 minute)

**What it does:** Creates a log group to store container logs

```bash
aws logs create-log-group \
  --log-group-name /ecs/central-llm-service \
  --region eu-central-1
```

---

### **Step 6: Register ECS Task Definition** (FREE - 2 minutes)

**What it does:** Defines how your container should run (image, resources, ports, etc.)

Create file `task-definition.json`:

```json
{
  "family": "central-llm-service",
  "networkMode": "bridge",
  "requiresCompatibilities": ["EC2"],
  "cpu": "4096",
  "memory": "16384",
  "executionRoleArn": "arn:aws:iam::396360117331:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::396360117331:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "vllm-server",
      "image": "396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest",
      "cpu": 4096,
      "memory": 16384,
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8000,
          "hostPort": 8000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "CUDA_VISIBLE_DEVICES",
          "value": "0"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/central-llm-service",
          "awslogs-region": "eu-central-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8000/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      },
      "resourceRequirements": [
        {
          "type": "GPU",
          "value": "1"
        }
      ]
    }
  ]
}
```

Register the task definition:

```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region eu-central-1
```

---

### **Step 7: Create ECS Service** (FREE - 2 minutes)

**What it does:** Creates a service that maintains the desired number of running tasks

```bash
aws ecs create-service \
  --cluster central-llm-service-cluster \
  --service-name central-llm-service \
  --task-definition central-llm-service \
  --desired-count 0 \
  --launch-type EC2 \
  --health-check-grace-period-seconds 300 \
  --deployment-configuration maximumPercent=200,minimumHealthyPercent=50 \
  --region eu-central-1
```

**Note:** Starting with `desired-count 0` to avoid costs until ready

---

### **Step 8: Launch EC2 Instance with GPU** ⚠️ **COST: $1.31/hour**

**What it does:** Launches a g6e.2xlarge GPU instance (48GB VRAM) that will run the vLLM container

```bash
aws ec2 run-instances \
  --image-id ami-0e0b995e4bdf1a25d \
  --instance-type g6e.2xlarge \
  --key-name central-llm-key \
  --security-group-ids sg-xxxxx \
  --iam-instance-profile Name=ecsInstanceRole \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=central-llm-ec2},{Key=ECS-Cluster,Value=central-llm-service-cluster}]' \
  --user-data '#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config' \
  --region eu-central-1
```

**Cost breakdown:**
- EC2 g6e.2xlarge: $1.31/hour (NVIDIA L40S with 48GB VRAM)
- EBS 100GB gp3: ~$0.80/month

**Why g6e.2xlarge?**
- ✅ 48GB VRAM (vs 24GB on g5.2xlarge) - supports full 32,768 token context
- ✅ Only $0.11/hour more than g5.2xlarge
- ✅ Newer GPU (L40S vs A10G)
- ✅ 2x system RAM (64GB vs 32GB)

**Output:** Note the `InstanceId` (e.g., `i-xxxxx`)

---

### **Step 9: Wait for Instance Registration** (FREE - 3-4 minutes)

#### 9.1 Check Instance Status
**What it does:** Verifies EC2 instance is running

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxx \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,State:State.Name,PublicIP:PublicIpAddress}'
```

**Expected output:** `State: running`, note the `PublicIP`

#### 9.2 Wait for Instance to be Running
**What it does:** Waits until instance reaches running state

```bash
aws ec2 wait instance-running \
  --instance-ids i-xxxxx \
  --region eu-central-1
```

#### 9.3 Check ECS Cluster Registration
**What it does:** Verifies instance has registered with ECS cluster

```bash
aws ecs describe-clusters \
  --clusters central-llm-service-cluster \
  --region eu-central-1 \
  --query 'clusters[0].{ClusterName:clusterName,RegisteredInstances:registeredContainerInstancesCount}'
```

**Expected:** `RegisteredInstances: 1` (may take 2-3 minutes)

---

### **Step 10: Start ECS Service** (FREE)

**What it does:** Tells ECS to start 1 task (container) on the registered instance

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

---

### **Step 11: Monitor Deployment** (FREE - 5-10 minutes)

The container will now:
1. Pull Docker image from ECR (~2-3 min for 54.6GB)
2. Start vLLM server (~1-2 min)
3. Load Ministral-8B model (~2-3 min)
4. Compile with torch.compile (~2-3 min)

#### 11.1 Check Service Status
**What it does:** Shows deployment progress

```bash
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'
```

**Expected progress:**
- Initially: `RunningCount: 0, PendingCount: 1`
- After 5-10 min: `RunningCount: 1, PendingCount: 0`

#### 11.2 List Running Tasks
**What it does:** Gets the task ARN for detailed inspection

```bash
aws ecs list-tasks \
  --cluster central-llm-service-cluster \
  --region eu-central-1
```

#### 11.3 Check Task Health (Optional)
**What it does:** Shows detailed task status including health checks

```bash
aws ecs describe-tasks \
  --cluster central-llm-service-cluster \
  --tasks <task-arn> \
  --region eu-central-1 \
  --query 'tasks[0].{LastStatus:lastStatus,HealthStatus:healthStatus}'
```

**Expected:** `LastStatus: RUNNING, HealthStatus: HEALTHY`

#### 11.4 View Logs (Optional)
**What it does:** Shows container logs for troubleshooting

```bash
aws logs tail /ecs/central-llm-service \
  --follow \
  --region eu-central-1
```

Press `Ctrl+C` to stop following logs.

---

### **Step 12: Get Public IP for Testing** (FREE)

**What it does:** Retrieves the public IP address to access the API

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

**Output:** Note the IP address (e.g., `3.75.196.125`)

---

## 🧪 Testing the API

### Health Check

**What it does:** Verifies the vLLM server is running and healthy

```bash
curl http://<PUBLIC-IP>:8000/health
```

**Expected output:** `{"status":"ok"}` or similar

### Test Chat Completion

**What it does:** Sends a test inference request to the model

```bash
curl -X POST http://<PUBLIC-IP>:8000/v1/chat/completions \
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

**Expected output:** JSON response with model-generated text

### Example Postman Request

**Endpoint:** `POST http://<PUBLIC-IP>:8000/v1/chat/completions`

**Headers:**
```
Content-Type: application/json
```

**Body (JSON):**
```json
{
  "model": "ministral-8b-instruct",
  "messages": [
    {
      "role": "user",
      "content": "Explain what is machine learning in one sentence."
    }
  ],
  "max_tokens": 100,
  "temperature": 0.7
}
```

---

## 🔐 SSH Access (Optional)

**What it does:** Connects to EC2 instance for debugging

```bash
ssh -i central-llm-key.pem ec2-user@<PUBLIC-IP>
```

### Useful Commands Inside Instance:

```bash
# View running containers
docker ps

# View container logs
docker logs <container-id>

# Check GPU status
nvidia-smi

# Check disk usage
df -h

# Check ECS agent status
sudo systemctl status ecs
```

---

## 🛑 How to Stop Costs

### When You're Done Testing:

#### Step 1: Stop ECS Service
**What it does:** Sets desired task count to 0, stopping all containers

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 0 \
  --region eu-central-1
```

#### Step 2: Terminate EC2 Instance
**What it does:** Terminates the instance to stop hourly charges

```bash
aws ec2 terminate-instances \
  --instance-ids i-xxxxx \
  --region eu-central-1
```

**Cost stops immediately after termination.**

---

## 🔄 How to Restart Later

To restart your POC without recreating everything:

#### 1. Launch New Instance
```bash
aws ec2 run-instances \
  --image-id ami-0e0b995e4bdf1a25d \
  --instance-type g6e.2xlarge \
  --key-name central-llm-key \
  --security-group-ids sg-xxxxx \
  --iam-instance-profile Name=ecsInstanceRole \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=central-llm-ec2}]' \
  --user-data '#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config' \
  --region eu-central-1
```

#### 2. Wait 3-4 Minutes for Registration

#### 3. Start Service
```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

#### 4. Get New Public IP
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

## 💰 Cost Summary

### One-Time Setup Costs:
- **All FREE** (IAM roles, ECS cluster, security groups, etc.)

### Running Costs:
| Resource | Cost | When Charged |
|----------|------|--------------|
| EC2 g6e.2xlarge | $1.31/hour | Only while running |
| EBS 100GB gp3 | ~$0.80/month | While volume exists |
| ECR Storage (54.6GB) | ~$5.46/month | Always (until image deleted) |

### Stopped Costs:
- Everything except ECR storage: **$0.00/hour**
- ECR storage only: **$5.46/month**

### Example Usage Costs:
- 1 hour test: ~$1.31
- 8 hour workday: ~$10.48
- 24/7 for 1 month: ~$943

### GPU Comparison:
| Instance | GPU | VRAM | Cost/hour | Max Context | Best For |
|----------|-----|------|-----------|-------------|----------|
| g5.2xlarge | A10G | 24GB | $1.20 | 24,576 tokens | Budget POC |
| **g6e.2xlarge** | **L40S** | **48GB** | **$1.31** | **32,768 tokens** | **Full context** ✅ |
| g5.4xlarge | A10G | 48GB | $2.40 | 32,768 tokens | Larger models |

---

## 📋 Quick Reference Commands

### Check Status
```bash
# EC2 instance status
aws ec2 describe-instances --instance-ids i-xxxxx --region eu-central-1

# ECS service status
aws ecs describe-services --cluster central-llm-service-cluster --services central-llm-service --region eu-central-1

# Container instances in cluster
aws ecs list-container-instances --cluster central-llm-service-cluster --region eu-central-1
```

### View Logs
```bash
# Real-time logs
aws logs tail /ecs/central-llm-service --follow --region eu-central-1

# Last 50 lines
aws logs tail /ecs/central-llm-service --since 10m --region eu-central-1
```

### Resource IDs to Replace
- `sg-xxxxx` → Your security group ID (from Step 3)
- `i-xxxxx` → Your instance ID (from Step 8)
- `<PUBLIC-IP>` → Your instance public IP (from Step 12)
- `<task-arn>` → Your task ARN (from Step 11.2)

---

## ⚠️ Troubleshooting

### Container Keeps Restarting
- Check logs: `aws logs tail /ecs/central-llm-service --region eu-central-1`
- Common issues:
  - Out of GPU memory (reduce `max-model-len`)
  - Port conflict (ensure port 8000 is free)
  - Image pull failure (check ECR permissions)

### Can't Access API
- Verify security group allows port 8000 from `0.0.0.0/0`
- Check instance has public IP
- Ensure container is healthy: `aws ecs describe-tasks ...`

### Instance Not Registering with ECS
- Check user data was applied: `ssh` to instance and check `/etc/ecs/ecs.config`
- Verify IAM instance profile is attached
- Check ECS agent: `sudo systemctl status ecs`

### SSH Connection Refused
- Ensure security group allows port 22
- Verify using correct key: `central-llm-key.pem`
- Check key permissions: `chmod 400 central-llm-key.pem`

---

## 🎯 Success Checklist

- [ ] All IAM roles created
- [ ] ECS cluster created
- [ ] Security group created with ports 8000 and 22 open
- [ ] SSH key pair created and saved
- [ ] Task definition registered
- [ ] ECS service created
- [ ] EC2 instance launched and registered with cluster
- [ ] Container running and healthy
- [ ] API responding to requests
- [ ] Can SSH into instance

---

## 📝 Notes

- **Region:** All commands use `eu-central-1`. Change if using different region.
- **Account ID:** Replace `396360117331` with your AWS account ID in task definition.
- **Model Context:** Full 32,768 tokens supported on g6e.2xlarge (48GB VRAM). Use g5.2xlarge ($1.20/hour) for 24,576 token budget option.
- **AMI:** `ami-0e0b995e4bdf1a25d` is the latest ECS GPU-optimized AMI (verified via SSM Parameter Store).
- **GPU:** g6e.2xlarge uses NVIDIA L40S - newer and faster than g5.2xlarge's A10G, only $0.11/hour more.
- **Networking:** Using bridge mode for simplicity. For production, consider awsvpc with load balancer.
- **Security:** API is publicly accessible. Add authentication for production use.

---

**Deployment completed!** 🚀

