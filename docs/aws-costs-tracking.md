# AWS Costs Tracking - Central LLM Service

## **Current Status: ✅ FREE (No Running Costs)**

| Service | Status | Cost/Hour | Monthly Cost | Notes |
|---------|--------|-----------|--------------|-------|
| ECR Repository | ✅ Created | FREE | FREE | First 500MB/month free |
| ECS Cluster | ✅ Created | FREE | FREE | Cluster itself is free |
| Security Group | ✅ Created | FREE | FREE | No cost for security groups |
| IAM Policies | ✅ Assigned | FREE | FREE | No cost for IAM |

## **Next Steps - COSTS WILL START:**

### **1. AWS CodeBuild (When We Run Builds)**
| Service | Cost | Duration | Total Cost | Notes |
|---------|------|----------|------------|-------|
| CodeBuild (BUILD_GENERAL1_LARGE) | $0.50/hour | ~30 minutes | ~$0.25 per build | Only when building |
| CloudWatch Logs | $0.50/GB | ~1GB per build | ~$0.50 per build | Build logs storage |

### **2. EC2 Instance (When We Deploy)**
| Service | Cost | Duration | Total Cost | Notes |
|---------|------|----------|------------|-------|
| g6e.2xlarge (GPU) | $1.20/hour | 24/7 | ~$864/month | Only when running |
| EBS Storage (100GB) | $0.10/GB | Monthly | ~$10/month | Model storage |

### **3. ECS Service (When We Deploy)**
| Service | Cost | Duration | Total Cost | Notes |
|---------|------|----------|------------|-------|
| ECS Service | FREE | 24/7 | FREE | Service orchestration |
| Application Load Balancer | $16.20/month | 24/7 | $16.20/month | Optional for production |

## **Total Estimated Costs:**

### **Development/Testing:**
- **CodeBuild**: $0.25 per build (only when building)
- **Total**: ~$0.25 per build

### **Production Deployment:**
- **EC2 g6e.2xlarge**: $864/month (24/7)
- **EBS Storage**: $10/month
- **ALB**: $16.20/month (optional)
- **Total**: ~$890/month

## **Cost Optimization:**
- ✅ **Stop EC2 when not needed** → $0/hour
- ✅ **Use smaller instance for testing** → $0.30/hour
- ✅ **Delete unused resources** → $0

## **Actions That Will Incur Costs:**
1. **CodeBuild execution** → ~$0.25 per build
2. **EC2 instance launch** → $1.20/hour
3. **EBS volume creation** → $0.10/GB/month

## **Actions That Are FREE:**
1. **Creating CodeBuild project** → FREE
2. **Creating EC2 instance** → FREE (until started)
3. **Creating ECS service** → FREE
4. **All IAM operations** → FREE
