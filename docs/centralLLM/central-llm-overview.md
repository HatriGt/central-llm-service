---
title: Central LLM Platform Overview
---

# Central LLM Platform — End-to-End Overview

This document captures the current production architecture of the Central LLM platform, including client access, request handling, inference, auditing, and observability.

## Solution Diagram

```
┌─────────────────────┐     ┌─────────────────────────┐     ┌─────────────────────┐
│ Client Applications │───►│ API Gateway (Usage Plan │───►│ NLB Target Group    │
│  • API key          │     │  + Header Validator)    │     │ central-llm-service │
│  • Audit headers    │     └─────────────────────────┘     └─────────┬──────────┘
└──────────┬──────────┘                                               │
           │ HTTPS                                                    │ Health checks
           ▼                                                          ▼
      ┌─────────────┐        ┌────────────────────────────────────────────────┐
      │  ECS Service├───────►│ GPU EC2 Task (vLLM + Audit Proxy Container)   │
      │  central-   │        │  • Forwards to vLLM runtime                    │
      │  llm-service│        │  • Writes audit JSON to S3                     │
      └────┬────────┘        └──────────────┬─────────────────────────────────┘
           │                                │
           │ Logs / metrics                 │ S3 PutObject (logs/YYYY/MM/DD/…)
           ▼                                ▼
   ┌────────────────┐            ┌─────────────────────────┐
   │ CloudWatch     │◄───────────│ S3 Bucket                │
   │ Logs / Metrics │            │ central-llm-audit/logs/… │
   └────────────────┘            └──────────────┬───────────┘
                                               │ Event notification
                                               ▼
                                 ┌─────────────────────────────┐
                                 │ Lambda llm-audit-ingest     │
                                 │  • Reads audit JSON         │
                                 │  • Uses DynamoDB + DLQ      │
                                 └──────────────┬──────────────┘
                                                │ PutItem / on failure
                                                ▼
                             ┌─────────────────────────┐    ┌────────────────┐
                             │ DynamoDB CentralLLMAudit│    │ SQS DLQ        │
                             │  • Queryable metadata   │    │  • Failed events│
                             └─────────────────────────┘    └────────────────┘
```

## Request Flow Summary

1. **Clients** (internal apps, automations) call the `/v1/chat/completions` REST endpoint with API keys and mandatory audit headers.
2. **API Gateway** authenticates via usage plans, validates headers, and forwards traffic to the Network Load Balancer target group.
3. **ECS Service** runs on GPU-backed EC2 instances. Each task starts the audit proxy (FastAPI) which:
   - Handles HTTP routing,
   - Forwards payloads to the local vLLM server,
   - Builds an audit JSON document and writes it to `s3://central-llm-audit/logs/YYYY/MM/DD/<requestId>.json`.
4. **S3** emits `ObjectCreated:Put` events (prefix `logs/`) that trigger the `llm-audit-ingest` Lambda, which enriches and persists metadata into DynamoDB.
5. **DynamoDB** stores the authoritative audit row, enabling downstream analytics, alerting, and governance.
6. **Monitoring**: CloudWatch ingests container logs, health checks, and Lambda metrics; DLQ captures failed audit ingestions.

## Key Artifacts

| Layer | Artifact | Purpose |
| --- | --- | --- |
| API Access | `aws/apigateway/*` (CLI commands in docs) | Enforce headers, deploy stages |
| Auth & Security | API keys stored in API Gateway usage plan | Gate client access |
| Compute | `aws/ecs-task-definition.json` | Container definition with `AUDIT_BUCKET`, health checks, GPU reservation |
| Image | CodeBuild project `mistral8b-vllm-build`, `docker/ecr-build/*` | Build and publish vLLM + audit proxy image |
| Launch Automation | `scripts/launch-prod-ecr.sh`, `scripts/shutdown-prod.sh` | Provision or retire GPU instances without AMIs |
| Audit Storage | `aws/policies/ecs-task-audit-writer.json` | Grants ECS task S3 write permission |
| Audit Bucket | `central-llm-audit` + prefix `logs/` | Durable storage for raw audit JSON |
| Ingestion Lambda | `infra/lambda/llm-audit-ingest/handler.py`, `inline-policy.json` | Convert audit JSON into DynamoDB records |
| Persistence | DynamoDB table `CentralLLMAudit` with GSIs | Query by project, user, status, latency |
| Observability | CloudWatch log groups `/ecs/central-llm-service`, `/aws/lambda/llm-audit-ingest` | Runtime diagnostics |

---

## Operational Responsibilities

- **Platform Team**
  - Maintain infrastructure CloudFormation / Terraform (when introduced) and IAM policies.
  - Operate ECS cluster capacity, respond to scaling or GPU resource alerts.
  - Keep CodeBuild and ECR images up to date with security patches.
  - Monitor audit ingestion success rate and DLQ backlog.
- **Application Teams**
  - Adhere to header requirements, manage API keys, handle request throttling.
  - Use DynamoDB / S3 audit data for compliance and troubleshooting.
- **Security & Compliance**
  - Review IAM policies stored under `aws/policies/`.
  - Validate S3 lifecycle, encryption, and DynamoDB point-in-time recovery settings.

---

## Runbooks & References

- `docs/audit/AUDIT-PIPELINE.md` — Detailed steps for audit configuration.
- `docs/COMPLETE-DEPLOYMENT-RUNBOOK.md` — Production deployment checklist.
- `docs/DEPLOYMENT-STEPS.md` — High-level CI/CD flow.
- `docs/centralLLM/central-llm-deployment-guide.md` — Full rebuild instructions for a new AWS environment.
- `scripts/ecs-host-logs.sh` — Tail ECS agent logs for troubleshooting.
- `scripts/logs-ecs-live.sh` / `logs-apigw-live.sh` — Real-time log streaming helpers.

---

## Change History

- **2025-11-10** — Migrated on-instance audit capture to S3 + Lambda ingestion.
- **2025-10-07** — Initial ECS + API Gateway deployment.
*** End Patch

