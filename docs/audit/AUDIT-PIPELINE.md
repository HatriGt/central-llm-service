# Central LLM Audit & Telemetry Pipeline

This guide documents the end-to-end pipeline that records every LLM request and response. The design now captures audit data inside the backend container, publishes it to S3, and lets a dedicated Lambda write the persistent record into DynamoDB.

All examples assume region `eu-central-1` and AWS CLI v2 with sufficient IAM permissions.

---

## 1. Standardise Client Metadata

Every request to `https://b3yr01g4hh.execute-api.eu-central-1.amazonaws.com/prod/v1/chat/completions` **must** include:

  - `x-api-key`: issued via usage plan `central-llm-usage-plan`.
  - `x-llm-source`: calling application (e.g. `finance-app`).
  - `x-llm-user`: end user or service account.
  - `x-llm-request-type`: logical action (`ask`, `summarise`, …).
- `x-request-id` *(optional)*: UUID provided by the caller (otherwise the backend generates one).

Document these requirements for all consuming teams (Confluence / runbook). The backend publisher and ingestion Lambda both expect the header names above.

---

## 2. Configure the Backend Audit Publisher

The ECR image now starts an audit proxy that fronts the vLLM server. Once inference completes the proxy emits a single JSON document containing request/response metadata to S3.

1. **Create / confirm the audit bucket**
   ```bash
   aws s3 mb s3://central-llm-audit --region eu-central-1
   ```
   Apply lifecycle policies as required (e.g. transition to Glacier or expire after N days).

2. **Grant the ECS task role (`ecsTaskRole`) permissions** to write objects. We keep the JSON in `aws/policies/ecs-task-audit-writer.json`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:AbortMultipartUpload"
         ],
         "Resource": "arn:aws:s3:::central-llm-audit/logs/*"
       },
       {
         "Effect": "Allow",
         "Action": "s3:ListBucket",
         "Resource": "arn:aws:s3:::central-llm-audit",
         "Condition": {
           "StringLike": {
             "s3:prefix": "logs/*"
           }
         }
       }
     ]
   }
   ```
   Apply with:
   ```bash
   aws iam put-role-policy \
     --role-name ecsTaskRole \
     --policy-name ecs-task-audit-writer \
     --policy-document file://aws/policies/ecs-task-audit-writer.json
   ```

3. **Set container environment variables** in the ECS task definition (or launch template):
   - `AUDIT_BUCKET=central-llm-audit`
   - Optional: `AUDIT_PREFIX=logs`, `AWS_REGION=eu-central-1`, `AUDIT_BODY_PREVIEW=2048`.

4. **Redeploy the service** with the new image tag once CodeBuild pushes it (see Section 6). The proxy listens on port `8000`, launches vLLM internally on `8001`, and writes `logs/YYYY/MM/DD/<requestId>.json` after each call.

---

## 3. Enforce Audit Headers in API Gateway

1. Require the metadata headers on the proxy resource:
   ```bash
   VALIDATOR_ID=$(
     aws apigateway create-request-validator \
       --rest-api-id b3yr01g4hh \
       --name validate-headers-and-body \
       --validate-request-parameters \
       --validate-request-body \
       --region eu-central-1 \
       --query 'id' \
       --output text
   )

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
       op=add,path=/requestParameters/method.request.header.x-llm-request-type,value=true \
       op=replace,path=/requestValidatorId,value=$VALIDATOR_ID

   aws apigateway create-deployment \
     --rest-api-id b3yr01g4hh \
     --stage-name prod \
     --description "Enforce audit headers" \
     --region eu-central-1
   ```

2. When a caller omits any of the headers, API Gateway now returns `400 Bad Request` and the proxy never receives the call.

---

## 4. Provision DynamoDB Storage

```bash
aws dynamodb create-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=id,AttributeType=S AttributeName=createdAt,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH AttributeName=createdAt,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1
```

Create the global secondary indexes one at a time:

```bash
# User/time index
aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=userIdPk,AttributeType=S AttributeName=userIdSk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_UserTime","KeySchema":[{"AttributeName":"userIdPk","KeyType":"HASH"},{"AttributeName":"userIdSk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]' \
  --region eu-central-1

aws dynamodb wait table-exists --table-name CentralLLMAudit --region eu-central-1

# Status/time index
aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=statusPk,AttributeType=S AttributeName=statusSk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_StatusTime","KeySchema":[{"AttributeName":"statusPk","KeyType":"HASH"},{"AttributeName":"statusSk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]' \
  --region eu-central-1

aws dynamodb wait table-exists --table-name CentralLLMAudit --region eu-central-1

# Latency index
aws dynamodb update-table \
  --table-name CentralLLMAudit \
  --attribute-definitions AttributeName=latencyPk,AttributeType=S AttributeName=latencySk,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"GSI_ProjectLatency","KeySchema":[{"AttributeName":"latencyPk","KeyType":"HASH"},{"AttributeName":"latencySk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}]' \
  --region eu-central-1
```

Schema enforced by the ingestion Lambda:
- `id = project#<x-llm-source>`
- `createdAt = <ISO8601 timestamp>#<requestId>`
- `userIdPk = user#<x-llm-user>` / `userIdSk = <timestamp>#<requestId>`
- `statusPk = status#<statusCode>` / `statusSk = <timestamp>#project#<requestId>`
- `latencyPk = project#<x-llm-source>` / `latencySk = latency#<latencyMs>#<timestamp>#<requestId>`
- Additional camelCase attributes: `statusCode`, `latencyMs`, `promptPreview`, `responsePreview`, `auditBucket`, `auditObjectKey`, etc.

---

## 5. Deploy the Ingestion Lambda (S3 Trigger)

1. **IAM role** (replace `<ACCOUNT_ID>` as needed). Trust policy lives at `infra/lambda/llm-audit-ingest/trust-policy.json`.
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
   Inline policy contents:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowDynamoAuditTable",
         "Effect": "Allow",
         "Action": [
           "dynamodb:PutItem",
           "dynamodb:UpdateItem",
           "dynamodb:DescribeTable"
         ],
         "Resource": [
           "arn:aws:dynamodb:eu-central-1:*:table/CentralLLMAudit",
           "arn:aws:dynamodb:eu-central-1:*:table/CentralLLMAudit/index/*"
         ]
       },
       {
         "Sid": "AllowReadAuditObjects",
         "Effect": "Allow",
         "Action": [
           "s3:GetObject"
         ],
         "Resource": "arn:aws:s3:::central-llm-audit/logs/*"
       },
       {
         "Sid": "AllowS3AuditArchive",
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:AbortMultipartUpload"
         ],
         "Resource": "arn:aws:s3:::central-llm-audit-raw/*",
         "Condition": {
           "StringEquals": {
             "s3:x-amz-acl": "bucket-owner-full-control"
           }
         }
       },
       {
         "Sid": "AllowDlqSendMessage",
         "Effect": "Allow",
         "Action": [
           "sqs:SendMessage"
         ],
         "Resource": "arn:aws:sqs:eu-central-1:<ACCOUNT_ID>:llm-audit-dlq"
       }
     ]
   }
   ```

2. **Package + deploy**:
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
     --region eu-central-1
   ```

3. **Dead-letter queue (recommended)**:
   ```bash
   aws sqs create-queue --queue-name llm-audit-dlq --region eu-central-1

   aws lambda update-function-configuration \
     --function-name llm-audit-ingest \
     --dead-letter-config TargetArn=arn:aws:sqs:eu-central-1:<ACCOUNT_ID>:llm-audit-dlq
   ```

4. **Subscribe to S3 events**:
   ```bash
   aws lambda add-permission \
     --function-name llm-audit-ingest \
     --statement-id AllowS3Invoke \
     --action lambda:InvokeFunction \
     --principal s3.amazonaws.com \
     --source-arn arn:aws:s3:::central-llm-audit \
     --source-account <ACCOUNT_ID> \
     --region eu-central-1

   aws s3api put-bucket-notification-configuration \
     --bucket central-llm-audit \
     --notification-configuration '{
       "LambdaFunctionConfigurations": [
         {
           "LambdaFunctionArn": "arn:aws:lambda:eu-central-1:<ACCOUNT_ID>:function:llm-audit-ingest",
           "Events": ["s3:ObjectCreated:Put"],
           "Filter": {
             "Key": {
               "FilterRules": [{"Name": "prefix", "Value": "logs"}]
             }
           }
         }
       ]
     }'
   ```

The Lambda now reads each JSON document, stores previews in DynamoDB, and records the S3 location of the full payload. The handler implementation is kept in `infra/lambda/llm-audit-ingest/handler.py`:
```python
def lambda_handler(event, _context):
    results = {"processed": 0, "written": 0, "skipped": 0, "errors": 0}
    for record in event.get("Records", []):
        if record.get("eventSource") != "aws:s3":
            continue
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        audit_doc = _load_audit_document(bucket, key)
        item = _parse_audit_document(audit_doc, bucket, key) if audit_doc else None
        if item:
            _write_audit_record(item)
            results["written"] += 1
        else:
            results["skipped"] += 1
    return results
```
See the source file for helper routines that normalise timestamps, truncate body previews, and guard against placeholder headers.

---

## 6. Build & Deploy the Backend Image

The `mistral8b-vllm-build` CodeBuild project pulls this repository, stages `docker/ecr-build/models/`, builds the Docker image, and pushes it to ECR. After pushing a new tag:

1. Update the ECS service (or runbook for manual launches) to use the new image digest.
2. Confirm `AUDIT_BUCKET` and other env vars are present in the task definition.
3. Redeploy / roll the service so that the audit proxy starts emitting S3 objects.

---

## 7. Validate & Query

1. Invoke the API with the mandatory headers.
2. Confirm `logs/YYYY/MM/DD/<requestId>.json` appears in `s3://central-llm-audit/` and contains request/response data.
3. Verify the Lambda wrote a DynamoDB item (`aws dynamodb get-item --table-name CentralLLMAudit ...`).
4. Build visualisations or alerts using DynamoDB (or export to S3/Athena) as needed.

---

## Reference Artifacts in This Repo

- `aws/policies/ecs-task-audit-writer.json` – IAM inline policy applied to `ecsTaskRole` for S3 writes.
- `infra/lambda/llm-audit-ingest/inline-policy.json` – Lambda ingest inline policy (DynamoDB + S3 read + DLQ).
- `infra/lambda/llm-audit-ingest/handler.py` – Lambda implementation for S3 → DynamoDB ingestion.
- `scripts/launch-prod-ecr.sh` – Launches EC2 instance and pulls ECR image directly (no AMI).
- `scripts/ecs-host-logs.sh` – Utility to SSH into the ECS host and tail `/var/log/ecs/ecs-agent.log`.
- `docker/ecr-build/app/audit_proxy.py` – FastAPI proxy that forwards to vLLM and publishes audit JSON to S3.

---

## Change Log

- **2025-11-10** – Switched audit ingestion to S3-based flow (backend proxy writes audit documents, Lambda consumes S3 events).
- **2025-11-09** – Initial version documenting CloudWatch-log-based audit pipeline.

