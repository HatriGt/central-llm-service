# LLM Audit Pipeline Flow

```
Client Applications
  (finance-app, etc.)
  Headers:
    - x-api-key
    - x-llm-source
    - x-llm-user
    - x-llm-request-type
    - x-request-id (optional)
        |
        | HTTPS POST /prod/v1/chat/completions
        v
API Gateway REST API (ID b3yr01g4hh, stage prod)
  - Validates API key
  - Logs to /aws/apigateway/central-llm-rest-api/prod
  - Forwards via VPC Link
        |
        v
Network Load Balancer central-llm-nlb
  Target group central-llm-nlb-tg
        |
        v
EC2 GPU / ECS container (vLLM)
  - Handles inference and writes container logs
        |
        v
API Gateway returns response to caller
```

```
Asynchronous Audit Pipeline

CloudWatch log group
  /aws/apigateway/central-llm-rest-api/prod
        |
        | Subscription filter "llm-audit"
        v
Lambda function llm-audit-ingest
  - Parses log event JSON
  - Masks secrets (no x-api-key)
  - Builds audit record
  - Writes to DynamoDB table CentralLLMAudit
      id         project#<x-llm-source>
      createdAt  <ISO8601 timestamp>#<requestId>
  - Optional: persists large prompt/response to S3 bucket central-llm-audit-raw
        |
        v
Downstream analytics
  - PartiQL / CLI queries on llm_audit
  - QuickSight or Athena (on exports)
```




+-----------------+        +--------------------------+
| Client Apps     |        | Cloud Foundry workload   |
| (finance-app,   |        | or other callers         |
| etc.)           |        |                         |
|-----------------|        | Send POST /v1/chat/...   |
| - x-api-key     |        | with headers:            |
| - x-llm-source  |        |   x-llm-source           |
| - x-llm-user    |        |   x-llm-user             |
| - x-llm-request |        |   x-llm-request-type     |
| - x-request-id? |        |   x-request-id (opt)     |
+--------+--------+        +-----------+--------------+
         |                               |
         | HTTPS request                  |
         v                               v
+-------------------------------------------------------------+
| API Gateway REST API (ID b3yr01g4hh, stage prod)            |
| - Validates key, forwards via VPC Link                      |
| - Access/execution logs -> CloudWatch log group             |
|   /aws/apigateway/central-llm-rest-api/prod                 |
+----------------------+--------------------------------------+
                       |
                       | VPC Link
                       v
              +-----------------------+
              | Network Load Balancer |
              | central-llm-nlb       |
              | targets: central-llm- |
              | nlb-tg (EC2 instance) |
              +-----------+-----------+
                          |
                          | TCP 8000
                          v
                +---------------------------+
                | EC2 GPU (ECS container)   |
                | vLLM service              |
                | Logs -> /ecs/central-llm- |
                | service (optional stream)|
                +-------------+-------------+
                              |
                              | Response
                              v
+-------------------------------------------------------------+
| API Gateway returns response to caller                      |
+-------------------------------------------------------------+

Asynchronous audit pipeline
---------------------------
1. CloudWatch log group `/aws/apigateway/central-llm-rest-api/prod`
   └─ Subscription filter `llm-audit`
       └─ Destination Lambda `llm-audit-ingest`
           • Parses log JSON (headers, body, status, latency)
           • Masks secrets (no `x-api-key`)
           • Writes/updates DynamoDB table `llm_audit`
               - PK: project#<x-llm-source>
               - SK: <timestamp>#<requestId>
               - GSIs: GSI_UserTime, GSI_StatusTime, GSI_ProjectLatency
           • If payload > 400 KB → S3 bucket `central-llm-audit-raw`
           • DLQ (SQS) for failures (optional)

Query/Reporting
---------------
- Use PartiQL / AWS CLI to query DynamoDB (`CentralLLMAudit`).
- Optional dashboards via QuickSight or Athena on exported data.
- Retention managed with DynamoDB TTL or S3 lifecycle.
