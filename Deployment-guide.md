# Deployment Steps - Central LLM Service

## 🎯 Goal
Deploy Ministral 8B model with vLLM on AWS ECS/EC2 and test via Postman

---

## ✅ Completed Steps

- [x] ECR Repository created: `mistral8b-vllm`
- [x] Docker image built and pushed to ECR
- [x] ECS Cluster created: `central-llm-service-cluster`
- [x] ECS Service created: `central-llm-service`
- [x] Security Group created: `sg-01348191cf1b4bc37`
- [x] IAM policies assigned to user

---

## 🚀 Next Steps

### **Step 1: Create IAM Roles for ECS Tasks** (FREE)

```bash
# Create ECS Task Execution Role
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

# Attach AWS managed policy
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Create ECS Task Role
aws iam create-role --role-name ecsTaskRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

# Create EC2 Instance Role for ECS
aws iam create-role --role-name ecsInstanceRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

# Attach AWS managed policy to instance role
aws iam attach-role-policy \
  --role-name ecsInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Create instance profile
aws iam create-instance-profile --instance-profile-name ecsInstanceRole

# Add role to instance profile
aws iam add-role-to-instance-profile \
  --instance-profile-name ecsInstanceRole \
  --role-name ecsInstanceRole
```

---

### **Step 2: Launch EC2 Instance with GPU** (⚠️ **$1.20/hour**)

```bash
# Launch g6e.2xlarge instance
aws ec2 run-instances \
  --image-id ami-0e0b995e4bdf1a25d \
  --instance-type g6e.2xlarge \
  --security-group-ids sg-01348191cf1b4bc37 \
  --subnet-id subnet-07b4b1c7bd77a628d \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=central-llm-ec2},{Key=ECS-Cluster,Value=central-llm-service-cluster}]' \
  --iam-instance-profile Name=ecsInstanceRole \
  --user-data '#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config' \
  --region eu-central-1
```

---

### **Step 3: Wait for Instance to Register** (FREE - ~5 minutes)

```bash
# Check instance status
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,State:State.Name,PublicIP:PublicIpAddress}'

# Wait for instance to be running
aws ec2 wait instance-running \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1

# Check ECS cluster capacity (wait until registeredContainerInstancesCount = 1)
aws ecs describe-clusters \
  --clusters central-llm-service-cluster \
  --region eu-central-1 \
  --query 'clusters[0].{ClusterName:clusterName,RegisteredInstances:registeredContainerInstancesCount,RunningTasks:runningTasksCount}'
```

---

### **Step 4: Update ECS Service to Deploy** (FREE)

```bash
# Update service to desired count 1
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

---

### **Step 5: Monitor Deployment** (FREE)

```bash
# Check service status
aws ecs describe-services \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1 \
  --query 'services[0].{Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'

# List running tasks
aws ecs list-tasks \
  --cluster central-llm-service-cluster \
  --region eu-central-1

# View task logs (if needed)
aws logs tail /ecs/central-llm-service --follow --region eu-central-1
```

---

### **Step 6: Get Public IP for Testing** (FREE)

```bash
# Get EC2 public IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

## 🧪 Test with Postman

### **Endpoint:**
```
POST http://<EC2-PUBLIC-IP>:8000/v1/chat/completions
```

### **Headers:**
```
Content-Type: application/json
```

### **Body (JSON):**
```json
{
  "model": "ministral-8b-instruct",
  "messages": [
    {
      "role": "user",
      "content": "Hello! Can you tell me a short joke?"
    }
  ],
  "max_tokens": 100,
  "temperature": 0.7
}
```

### **Expected Response:**
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1234567890,
  "model": "ministral-8b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Why don't scientists trust atoms? Because they make up everything!"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 20,
    "total_tokens": 35
  }
}
```

---

## 🛑 How to Stop Costs

### **When You're Done Testing:**
```bash
# Stop ECS service (sets desired count to 0)
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 0 \
  --region eu-central-1

# Terminate EC2 instance
aws ec2 terminate-instances \
  --instance-ids <INSTANCE-ID> \
  --region eu-central-1
```

---

## 💰 Cost Summary

| Step | Cost | Duration | Total |
|------|------|----------|-------|
| Step 1 (IAM roles) | FREE | 1 minute | $0 |
| Step 2 (Launch EC2) | $1.20/hour | Ongoing | Starts immediately |
| Step 3-6 | FREE | 15 minutes | $0 |
| Testing | Included | As needed | Included in EC2 cost |
| **Total Running Cost** | **$1.20/hour** | **While running** | **~$0.30 for 15 min test** |

---

## 📋 Timeline

- **Step 1**: 2 minutes (IAM roles)
- **Step 2**: 5 minutes (EC2 launch)
- **Step 3**: 5 minutes (Wait for registration)
- **Step 4**: 2 minutes (Deploy service)
- **Step 5**: 10 minutes (Container startup)
- **Step 6**: 1 minute (Get IP)
- **Testing**: As needed
- **Total**: ~25-30 minutes

---

## 🎯 Quick Start (Copy-Paste All Commands)

Run these in sequence:

```bash
# Step 1: Create IAM Roles (FREE)
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam create-role --role-name ecsTaskRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name ecsInstanceRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name ecsInstanceRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
aws iam create-instance-profile --instance-profile-name ecsInstanceRole
aws iam add-role-to-instance-profile --instance-profile-name ecsInstanceRole --role-name ecsInstanceRole

# Step 2: Launch EC2 (COSTS $1.20/hour - starts immediately)
aws ec2 run-instances --image-id ami-0e0b995e4bdf1a25d --instance-type g6e.2xlarge --security-group-ids sg-01348191cf1b4bc37 --subnet-id subnet-07b4b1c7bd77a628d --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=central-llm-ec2},{Key=ECS-Cluster,Value=central-llm-service-cluster}]' --iam-instance-profile Name=ecsInstanceRole --user-data '#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config' --region eu-central-1

# Step 3: Wait and check (run after 5 minutes)
aws ecs describe-clusters --clusters central-llm-service-cluster --region eu-central-1 --query 'clusters[0].{ClusterName:clusterName,RegisteredInstances:registeredContainerInstancesCount}'

# Step 4: Deploy service
aws ecs update-service --cluster central-llm-service-cluster --service central-llm-service --desired-count 1 --region eu-central-1

# Step 5: Get public IP (run after 5 minutes)
aws ec2 describe-instances --filters "Name=tag:Name,Values=central-llm-ec2" --region eu-central-1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

---

## ✅ Ready to Deploy?

**Next action**: Run Step 1 commands (FREE) to create IAM roles.
