# Central LLM Service - AWS Deployment

## Current Status
✅ **ECR Repository**: `mistral8b-vllm` created in `eu-central-1`  
✅ **Docker Image**: Built successfully with Ministral 8B model  
⏳ **Next Step**: Push to ECR (requires IAM permissions)

## Required IAM Policy

**User**: `ajeeth.kumar.atom`  
**Policy Name**: `ECRAccess-mistral8b-vllm`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:eu-central-1:396360117331:repository/mistral8b-vllm"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    }
  ]
}
```

### 2. Test Locally
```bash
# Start the server
docker-compose up

# In another terminal, test the API
python3 test_client.py
```

## Prerequisites

1. **AWS CLI configured** with appropriate permissions
2. **Docker installed** and running
3. **AWS Account** with ECR permissions

## Quick Deployment

### 1. Build and Push to ECR

```bash
# Run the automated build and push script
./build-and-push-ecr.sh
```

This script will:
- Create ECR repository if it doesn't exist
- Build the Docker image
- Push to AWS ECR
- Provide deployment information

### 2. Manual Build (Alternative)

If the script fails, build manually:

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# Build image
docker build -t central-llm-service .

# Tag for ECR
docker tag central-llm-service:latest YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/central-llm-service:latest

# Push to ECR
docker push YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/central-llm-service:latest
```

## ECS Setup

### 1. Create ECS Cluster

```bash
aws ecs create-cluster --cluster-name central-llm-cluster
```

### 2. Create Task Definition

Update `ecs-task-definition.json` with your account ID:

```bash
# Replace YOUR_ACCOUNT_ID with your actual AWS account ID
sed -i 's/YOUR_ACCOUNT_ID/YOUR_ACTUAL_ACCOUNT_ID/g' ecs-task-definition.json

# Register task definition
aws ecs register-task-definition --cli-input-json file://ecs-task-definition.json
```

### 3. Create CloudWatch Log Group

```bash
aws logs create-log-group --log-group-name /ecs/central-llm-service
```

### 4. Deploy Service

Update `ecs-service-definition.json` with your infrastructure IDs:

```bash
# Replace placeholders with actual values
# - YOUR_SUBNET_ID: Your VPC subnet ID
# - YOUR_SECURITY_GROUP_ID: Your security group ID
# - YOUR_TARGET_GROUP_ID: Your ALB target group ID

# Create service
aws ecs create-service --cli-input-json file://ecs-service-definition.json
```

## Infrastructure Requirements

### EC2 Instance Type
- **Recommended**: `g4dn.xlarge` or larger
- **Minimum**: `g4dn.large`
- **GPU**: NVIDIA T4 or better

### Security Group
Allow inbound traffic on port 8000:

```bash
# Create security group
aws ec2 create-security-group --group-name central-llm-sg --description "Security group for Central LLM Service"

# Allow HTTP traffic on port 8000
aws ec2 authorize-security-group-ingress --group-name central-llm-sg --protocol tcp --port 8000 --cidr 0.0.0.0/0
```

### Application Load Balancer (Optional)

```bash
# Create ALB
aws elbv2 create-load-balancer --name central-llm-alb --subnets subnet-YOUR_SUBNET_ID

# Create target group
aws elbv2 create-target-group --name central-llm-tg --protocol HTTP --port 8000 --vpc-id vpc-YOUR_VPC_ID --target-type ip
```

## Testing the Deployment

### 1. Check Service Status

```bash
aws ecs describe-services --cluster central-llm-cluster --services central-llm-service
```

### 2. Test API Endpoints

```bash
# Health check
curl http://YOUR_ALB_DNS_NAME:8000/health

# Chat completion
curl -X POST "http://YOUR_ALB_DNS_NAME:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-8b-instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

## Monitoring

### CloudWatch Metrics
- CPU and memory utilization
- GPU utilization (if available)
- Request count and latency

### Logs
```bash
# View logs
aws logs describe-log-streams --log-group-name /ecs/central-llm-service
aws logs get-log-events --log-group-name /ecs/central-llm-service --log-stream-name STREAM_NAME
```

## Troubleshooting

### Common Issues

1. **Task fails to start**
   - Check ECR repository permissions
   - Verify task definition resources
   - Check CloudWatch logs

2. **GPU not available**
   - Ensure EC2 instance has GPU
   - Check ECS cluster capacity providers
   - Verify task definition GPU requirements

3. **Out of memory**
   - Increase task memory allocation
   - Use larger EC2 instance type
   - Adjust vLLM memory utilization

### Useful Commands

```bash
# List running tasks
aws ecs list-tasks --cluster central-llm-cluster

# Describe task
aws ecs describe-tasks --cluster central-llm-cluster --tasks TASK_ARN

# Update service
aws ecs update-service --cluster central-llm-cluster --service central-llm-service --desired-count 1
```

## Cost Optimization

1. **Use Spot Instances** for development
2. **Auto Scaling** based on demand
3. **Reserved Instances** for production
4. **CloudWatch alarms** for cost monitoring

## Security Best Practices

1. **VPC** with private subnets
2. **Security groups** with minimal access
3. **IAM roles** with least privilege
4. **Secrets Manager** for sensitive data
5. **WAF** for application protection


