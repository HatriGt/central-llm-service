---
title: Central LLM Deployment Guide
---

# Central LLM Deployment Guide

This playbook walks through recreating the Central LLM platform in a new AWS environment. Follow the steps in order; every command assumes region `eu-central-1` unless otherwise noted.

## 1. Prerequisites

- AWS account with administrative access.
- CLI tooling:
  - AWS CLI v2
  - `bun` (for running helper scripts)
  - `zip`
- Git checkout of `central-llm-service` repository.
- Chosen VPC with public subnets that expose the GPU instances behind a Network Load Balancer.
- Domain or Route 53 records (optional) if you plan to expose the API via a custom hostname.

> **Note:** All resource names used below match production. Adjust if deploying into a separate environment (e.g., append `-staging`).

## 2. Parameter Sheet

| Parameter | Example | Notes |
| --- | --- | --- |
| AWS Region | `eu-central-1` | Update commands if you deploy elsewhere |
| VPC ID | `vpc-xxxxxxxx` | Must contain public subnets for NLB |
| Subnet IDs | `subnet-aaa, subnet-bbb` | Attach to NLB and EC2 instances |
| Security Group | `sg-xxxxxxxx` | Allow inbound 443/80 (API) and 8000 (internal) |
| ECS Cluster | `central-llm-service-cluster` | GPU-capable EC2 capacity |
| ECS Service | `central-llm-service` | Desired count: 1+ tasks |
| S3 Buckets | `central-llm-audit`, `central-llm-audit-raw` | Audit storage |
| DynamoDB Table | `CentralLLMAudit` | PAY_PER_REQUEST |
| Lambda | `llm-audit-ingest` | S3-triggered audit ingestion |
| DLQ | `llm-audit-dlq` | SQS queue for failed audit events |
| ECR Repo | `mistral8b-vllm` | Holds inference image |
| CodeBuild Project | `mistral8b-vllm-build` | Builds/pushes Docker image |

## 3. Storage Layer

### 3.1 S3 Buckets

```bash
aws s3 mb s3://central-llm-audit --region eu-central-1
aws s3 mb s3://central-llm-audit-raw --region eu-central-1
```

Configure bucket encryption, versioning, and lifecycle rules as required by your organisation.

### 3.2 DynamoDB Table and GSIs

```bash
aws dynamodb create-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=id,AttributeType=S AttributeName=createdAt,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH AttributeName=createdAt,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1

aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=userIdPk,AttributeType=S AttributeName=userIdSk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_UserTime","KeySchema":[{"AttributeName":"userIdPk","KeyType":"HASH"},{"AttributeName":"userIdSk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]'

aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=statusPk,AttributeType=S AttributeName=statusSk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_StatusTime","KeySchema":[{"AttributeName":"statusPk","KeyType":"HASH"},{"AttributeName":"statusSk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]'

aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=latencyPk,AttributeType=S AttributeName=latencySk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_ProjectLatency","KeySchema":[{"AttributeName":"latencyPk","KeyType":"HASH"},{"AttributeName":"latencySk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]'
```

### 3.3 SQS Dead Letter Queue

```bash
aws sqs create-queue --queue-name llm-audit-dlq --region eu-central-1
```

## 4. IAM Roles and Policies

### 4.1 ECS Task Role

1. Create (if not already present):
   ```bash
   aws iam create-role \
     --role-name ecsTaskRole \
     --assume-role-policy-document '{
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Principal": { "Service": "ecs-tasks.amazonaws.com" },
           "Action": "sts:AssumeRole"
         }
       ]
     }'
   ```
2. Apply the audit writer inline policy stored at `aws/policies/ecs-task-audit-writer.json`:
   ```bash
   aws iam put-role-policy \
     --role-name ecsTaskRole \
     --policy-name ecs-task-audit-writer \
     --policy-document file://aws/policies/ecs-task-audit-writer.json
   ```

### 4.2 Lambda Execution Role

```bash
aws iam create-role \
  --role-name llm-audit-ingest-role \
  --assume-role-policy-document file://infra/lambda/llm-audit-ingest/trust-policy.json

aws iam attach-role-policy \
  --role-name llm-audit-ingest-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam put-role-policy \
  --role-name llm-audit-ingest-role \
  --policy-name llm-audit-ingest-inline \
  --policy-document file://infra/lambda/llm-audit-ingest/inline-policy.json
```

### 4.3 CodeBuild Service Role (if new)

```bash
aws iam create-role \
  --role-name codebuild-mistral8b-vllm-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "codebuild.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

aws iam attach-role-policy \
  --role-name codebuild-mistral8b-vllm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

## 5. ECR and CodeBuild

```bash
aws ecr create-repository --repository-name mistral8b-vllm --region eu-central-1
```

Create CodeBuild project referencing `aws/buildspec.yml`:

```bash
aws codebuild create-project \
  --name mistral8b-vllm-build \
  --source type=GITHUB,location=https://github.com/<ORG>/central-llm-service.git \
  --artifacts type=NO_ARTIFACTS \
  --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_LARGE,privilegedMode=true \
  --service-role arn:aws:iam::<ACCOUNT_ID>:role/codebuild-mistral8b-vllm-role \
  --buildspec aws/buildspec.yml \
  --region eu-central-1
```

> Update the Git repository URL and service role ARN with real values.

## 6. Lambda Deployment

```bash
zip -j infra/lambda/llm-audit-ingest/dist.zip infra/lambda/llm-audit-ingest/handler.py

aws lambda create-function \
  --function-name llm-audit-ingest \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/llm-audit-ingest-role \
  --handler handler.lambda_handler \
  --timeout 60 \
  --environment Variables={TABLE_NAME=CentralLLMAudit,MAX_PREVIEW_CHARS=2048} \
  --zip-file fileb://infra/lambda/llm-audit-ingest/dist.zip \
  --dead-letter-config TargetArn=arn:aws:sqs:eu-central-1:<ACCOUNT_ID>:llm-audit-dlq \
  --region eu-central-1
```

### 6.1 S3 Notification & Lambda Permission

```bash
aws lambda add-permission \
  --function-name llm-audit-ingest \
  --statement-id AllowS3Invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::central-llm-audit \
  --source-account <ACCOUNT_ID>

aws s3api put-bucket-notification-configuration \
  --bucket central-llm-audit \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [
      {
        "LambdaFunctionArn": "arn:aws:lambda:eu-central-1:<ACCOUNT_ID>:function:llm-audit-ingest",
        "Events": ["s3:ObjectCreated:Put"],
        "Filter": { "Key": { "FilterRules": [ { "Name": "prefix", "Value": "logs" } ] } }
      }
    ]
  }'
```

## 7. API Gateway

1. Create REST API (if not existing):
   ```bash
   REST_API_ID=$(aws apigateway create-rest-api \
     --name central-llm-rest-api \
     --region eu-central-1 \
     --query 'id' \
     --output text)
   ```
2. Configure resources, methods, and integration to the NLB. See `docs/audit/AUDIT-PIPELINE.md` Section 3 for header enforcement commands.
3. Deploy:
   ```bash
   aws apigateway create-deployment \
     --rest-api-id $REST_API_ID \
     --stage-name prod \
     --description "Initial Central LLM deployment" \
     --region eu-central-1
   ```
4. Create usage plan, API key, and associate them:
   ```bash
   USAGE_PLAN_ID=$(aws apigateway create-usage-plan \
     --name central-llm-usage-plan \
     --throttle burstLimit=50,rateLimit=100 \
     --quota limit=100000,period=MONTH \
     --region eu-central-1 \
     --query 'id' \
     --output text)

   API_KEY_ID=$(aws apigateway create-api-key \
     --name central-llm-generic-key \
     --enabled \
     --region eu-central-1 \
     --query 'id' \
     --output text)

  aws apigateway create-usage-plan-key \
     --usage-plan-id $USAGE_PLAN_ID \
     --key-type API_KEY \
     --key-id $API_KEY_ID \
     --region eu-central-1
   ```

## 8. ECS Cluster and Service

1. Create ECS cluster (if needed):
   ```bash
   aws ecs create-cluster --cluster-name central-llm-service-cluster --region eu-central-1
   ```
2. Provision GPU instances. Recommended approach: use an Auto Scaling Group with a launch template that installs the ECS agent (`amazon-ecs-init`) and joins the cluster. Alternatively, run the scripted launch:
   ```bash
   export CLUSTER=central-llm-service-cluster
   export SERVICE=central-llm-service
   export REGION=eu-central-1
   bun run launch:ecr
   ```
3. Register task definition using `aws/ecs-task-definition.json` (update image URI if needed):
   ```bash
   aws ecs register-task-definition \
     --cli-input-json file://aws/ecs-task-definition.json \
     --region eu-central-1
   ```
4. Create or update the service:
   ```bash
   aws ecs create-service \
     --cluster central-llm-service-cluster \
     --service-name central-llm-service \
     --task-definition central-llm-service \
     --launch-type EC2 \
     --desired-count 1 \
     --deployment-configuration maximumPercent=200,minimumHealthyPercent=50 \
     --region eu-central-1
   ```

Ensure the service is registered with the correct load balancer target group or manually register the instance if using the launch script.

## 9. Build and Publish the Container

1. Trigger CodeBuild:
   ```bash
   aws codebuild start-build --project-name mistral8b-vllm-build --region eu-central-1
   ```
2. Wait for success, then roll the ECS service to pull the new image:
   ```bash
   aws ecs update-service \
     --cluster central-llm-service-cluster \
     --service central-llm-service \
     --force-new-deployment \
     --region eu-central-1
   ```

## 10. Validation Checklist

1. **API Call**: Issue a request with required headers:
   ```bash
   curl -sS -X POST \
     -H "x-api-key: <API_KEY_VALUE>" \
     -H "Content-Type: application/json" \
     -H "x-llm-source: smoke-test" \
     -H "x-llm-user: qa" \
     -H "x-llm-request-type: chat" \
     --data '{"model":"ministral-8b-instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":16}' \
     https://<API_ID>.execute-api.eu-central-1.amazonaws.com/prod/v1/chat/completions
   ```
2. **S3 Audit**: Confirm JSON object exists under `s3://central-llm-audit/logs/YYYY/MM/DD/<requestId>.json`.
3. **Lambda Logs**: `aws logs tail /aws/lambda/llm-audit-ingest --since 5m`.
4. **DynamoDB Entry**: Query `CentralLLMAudit` for `project#smoke-test`.
5. **ECS Task Health**: `aws ecs describe-services --cluster central-llm-service-cluster --services central-llm-service`.

## 11. Observability Setup

- Configure CloudWatch alarms for ECS service health, Lambda errors, and DLQ message count.
- Optionally send audit metrics to Datadog/Prometheus using CloudWatch Events or custom exporters.

## 12. Cleanup (if needed)

To tear down the environment:

```bash
aws ecs delete-service --cluster central-llm-service-cluster --service central-llm-service --force
aws ecs delete-cluster --cluster central-llm-service-cluster
aws lambda delete-function --function-name llm-audit-ingest
aws s3 rb s3://central-llm-audit --force
aws s3 rb s3://central-llm-audit-raw --force
aws dynamodb delete-table --table-name CentralLLMAudit
aws sqs delete-queue --queue-url https://sqs.eu-central-1.amazonaws.com/<ACCOUNT_ID>/llm-audit-dlq
aws ecr delete-repository --repository-name mistral8b-vllm --force
aws codebuild delete-project --name mistral8b-vllm-build
aws apigateway delete-rest-api --rest-api-id b3yr01g4hh
```

Remove IAM roles/policies if they are no longer required.

---

**Related Docs**
- `docs/centralLLM/central-llm-overview.md` — Architecture overview and flow.
- `docs/centralLLM/central-llm-technical-reference.md` — Component-level configuration details.
- `docs/audit/AUDIT-PIPELINE.md` — Additional context on the audit subsystem.

