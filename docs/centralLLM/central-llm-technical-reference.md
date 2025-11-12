---
title: Central LLM Technical Reference
---

# Central LLM Technical Reference

This document aggregates the technical specifics required to build, deploy, and operate the Central LLM stack, including configuration snippets, IAM policies, build pipelines, and operational commands.

## 1. Infrastructure Components

### 1.1 API Gateway

- **REST API ID**: `b3yr01g4hh`
- **Stage**: `prod`
- **Key Configuration**
  ```bash
  # Enforce audit headers
  RESOURCE_ID=$(aws apigateway get-resources \
    --rest-api-id b3yr01g4hh \
    --region eu-central-1 \
    --query 'items[?path==`/{proxy+}`].id' \
    --output text)

  aws apigateway update-method \
    --rest-api-id b3yr01g4hh \
    --resource-id "$RESOURCE_ID" \
    --http-method ANY \
    --region eu-central-1 \
    --patch-operations \
      op=add,path=/requestParameters/method.request.header.x-llm-source,value=true \
      op=add,path=/requestParameters/method.request.header.x-llm-user,value=true \
      op=add,path=/requestParameters/method.request.header.x-llm-request-type,value=true
  ```
- **Usage Plan**: `central-llm-usage-plan` (stores API keys for clients).

### 1.2 Network Load Balancer + Target Group

- **Target Group Name**: `central-llm-service`
- **Port**: `8000` (proxy)
- **Health Check**: GET `/health` every 30s, timeout 5s, 3 retries.

### 1.3 ECS Cluster

- **Cluster Name**: `central-llm-service-cluster`
- **Service Name**: `central-llm-service`
- **Launch Type**: `EC2`
- **Capacity**: GPU-enabled instances (p4d / g5 based on availability).
- **Task Definition**: `aws/ecs-task-definition.json`
  ```json
  {
    "family": "central-llm-service",
    "containerDefinitions": [
      {
        "name": "vllm-server",
        "image": "<ACCOUNT_ID>.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest",
        "cpu": 4096,
        "memory": 16384,
        "environment": [
          {"name": "AUDIT_BUCKET", "value": "central-llm-audit"},
          {"name": "AUDIT_PREFIX", "value": "logs"},
          {"name": "AWS_REGION", "value": "eu-central-1"},
          {"name": "CUDA_VISIBLE_DEVICES", "value": "0"}
        ],
        "resourceRequirements": [{"type": "GPU", "value": "1"}],
        "healthCheck": {
          "command": ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"],
          "interval": 30,
          "timeout": 5,
          "retries": 3,
          "startPeriod": 60
        }
      }
    ]
  }
  ```

### 1.4 IAM Roles & Policies

#### ECS Task Role (`ecsTaskRole`)

Policy file `aws/policies/ecs-task-audit-writer.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::central-llm-audit/logs/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::central-llm-audit",
      "Condition": { "StringLike": { "s3:prefix": "logs/*" } }
    }
  ]
}
```

#### Lambda Role (`llm-audit-ingest-role`)

Inline policy `infra/lambda/llm-audit-ingest/inline-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDynamoAuditTable",
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DescribeTable"],
      "Resource": [
        "arn:aws:dynamodb:eu-central-1:*:table/CentralLLMAudit",
        "arn:aws:dynamodb:eu-central-1:*:table/CentralLLMAudit/index/*"
      ]
    },
    {
      "Sid": "AllowReadAuditObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::central-llm-audit/logs/*"
    },
    {
      "Sid": "AllowS3AuditArchive",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::central-llm-audit-raw/*",
      "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control" } }
    },
    {
      "Sid": "AllowDlqSendMessage",
      "Effect": "Allow",
      "Action": ["sqs:SendMessage"],
      "Resource": "arn:aws:sqs:eu-central-1:<ACCOUNT_ID>:llm-audit-dlq"
    }
  ]
}
```

### 1.5 Storage

- **Audit Bucket**: `central-llm-audit`
  - Prefix structure: `logs/YYYY/MM/DD/<requestId>.json`
  - Event notifications: `s3:ObjectCreated:Put`, filter prefix `logs/`.
- **Raw Archive Bucket** *(optional)*: `central-llm-audit-raw` for long-term storage.
- **DynamoDB Table**: `CentralLLMAudit` with GSIs (`GSI_UserTime`, `GSI_StatusTime`, `GSI_ProjectLatency`).

## 2. Build & Deployment Pipeline

### 2.1 Container Build

- Repository: CodeBuild project `mistral8b-vllm-build`
- Buildspec: `aws/buildspec.yml`
  - Steps: 
    1. Install dependencies.
    2. Download model artifacts into `docker/ecr-build/models/`.
    3. Build Docker image from `docker/ecr-build/Dockerfile`.
    4. Push to ECR repo `mistral8b-vllm`.

### 2.2 Deploy to ECS

- After ECR push, trigger service redeploy:
  ```bash
  aws ecs update-service \
    --cluster central-llm-service-cluster \
    --service central-llm-service \
    --force-new-deployment \
    --region eu-central-1
  ```

- Manual launch alternative: `scripts/launch-prod-ecr.sh` (resolves latest ECS GPU AMI, attaches security groups, starts instance, waits for service stability).

### 2.3 Lambda Packaging

```bash
zip -j infra/lambda/llm-audit-ingest/dist.zip infra/lambda/llm-audit-ingest/handler.py
aws lambda update-function-code \
  --function-name llm-audit-ingest \
  --zip-file fileb://infra/lambda/llm-audit-ingest/dist.zip \
  --region eu-central-1
```

## 3. Runtime Components

### 3.1 Audit Proxy (`docker/ecr-build/app/audit_proxy.py`)

- Launches FastAPI app on port 8000, proxies inference calls to vLLM (port 8001).
- Captures metadata: headers, request/response bodies, latency, HTTP status.
- Writes JSON payload to S3:
  ```python
  audit_key = f"{AUDIT_PREFIX}/{utc_date}/{request_id}.json"
  s3_client.put_object(
      Bucket=AUDIT_BUCKET,
      Key=audit_key,
      Body=json.dumps(audit_record).encode("utf-8"),
      ContentType="application/json",
  )
  ```
- Logs failure to S3 and continues returning vLLM response to clients.

### 3.2 Ingestion Lambda (`handler.py`)

- Reads S3 object, sanitises placeholder values, builds DynamoDB item:
  ```python
  item = {
      "id": f"project#{project}",
      "createdAt": f"{iso_ts}#{request_id}",
      "requestId": request_id,
      "projectId": project,
      "userId": user_id,
      "statusCode": status_code,
      "latencyMs": latency,
      "promptPreview": preview(request_body),
      "responsePreview": preview(response_body),
      "auditBucket": bucket,
      "auditObjectKey": key,
  }
  table.put_item(Item=item)
  ```
- Environment variables:
  - `TABLE_NAME=CentralLLMAudit`
  - `MAX_PREVIEW_CHARS=2048`

## 4. Observability & Operations

### 4.1 Logging Commands

- ECS container logs:
  ```bash
  aws logs tail /ecs/central-llm-service --since 5m --region eu-central-1
  ```
- Lambda logs:
  ```bash
  aws logs tail /aws/lambda/llm-audit-ingest --since 5m --region eu-central-1
  ```
- ECS host debugging:
  ```bash
  bun run logs:host  # wraps scripts/ecs-host-logs.sh
  ```

### 4.2 Health Checks

- `/health` endpoint served by audit proxy; used by NLB and ECS.
- CloudWatch alarms should be configured for:
  - ECS service `RunningTaskCount` < `DesiredCount`.
  - Lambda `Errors` > 0 / DLQ queue depth.
  - S3 event failure or missing audit objects (future enhancement).

## 5. Configuration Reference

| Component | Location | Notes |
| --- | --- | --- |
| API Gateway validation | `docs/audit/AUDIT-PIPELINE.md` Section 3 | Required headers |
| ECS task definition | `aws/ecs-task-definition.json` | Container env vars & health checks |
| ECS launch script | `scripts/launch-prod-ecr.sh` | Boot GPU hosts from ECR |
| IAM policies | `aws/policies/ecs-task-audit-writer.json`, `infra/lambda/llm-audit-ingest/inline-policy.json` | S3 + DynamoDB access |
| Lambda code | `infra/lambda/llm-audit-ingest/handler.py` | Audit ingestion |
| Docker build context | `docker/ecr-build/` | Proxy + vLLM image |
| Audit documentation | `docs/audit/AUDIT-PIPELINE.md` | Detailed pipeline steps |
| Deployment guide | `docs/centralLLM/central-llm-deployment-guide.md` | End-to-end provisioning instructions |

## 6. Future Enhancements

- Add DataDog / Prometheus exporters for GPU utilization and inference latency.
- Introduce Infrastructure as Code (CloudFormation/Terraform) to manage current manual scripts.
- Implement S3 lifecycle transitions and DynamoDB TTL for aging audit records.
- Expand smoke tests for audit pipeline (automated invocation + validation).

---

For questions or updates, contact the Central LLM platform team.

