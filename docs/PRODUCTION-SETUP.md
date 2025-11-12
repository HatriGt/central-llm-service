# Production Setup Guide - Central LLM Service

This document captures the production-ready layout for the central LLM API. It lists all components built so far, why each exists, and the steps to spin the stack up or down safely.

---

## Components & Purpose

- **AMI `ami-0ea47fea769e59918` (central-llm-vllm-ami)**  
  Pre-baked Amazon Linux 2 image with vLLM Docker layers cached. Purpose: eliminate multi-minute pulls when launching GPU hosts.

- **Launch Template `central-llm-launch-template`**  
  Encapsulates instance type `g6e.2xlarge`, IAM profile, security group, and ECS GPU user data. Purpose: one-command EC2 launches aligned with the AMI.

- **Internal NLB `central-llm-nlb` + Target Group `central-llm-nlb-tg`**  
  Network Load Balancer listening on port 8000 and forwarding to ECS instances. Purpose: required hop so the API Gateway VPC link can reach the private GPU host; make sure only the active instance stays registered.

- **API Gateway REST API `central-llm-rest-api` (stage `prod`)**  
  Front door requiring API keys. Usage plan (`central-llm-usage-plan`) throttles to 5 req/s (burst 10) and 5 000 req/day. API key `central-llm-client` issued for clients. Purpose: secure ingress, rate limiting, audit.

- **Security Groups**  
  - `central-llm-service-sg`: now permits port 8000 only from the REST API VPC link ENIs. Purpose: ensure traffic passes through Gateway.  
  - Clean up any leftover security groups tied to the deprecated HTTP API path.

- **Audit & Observability Pipeline**  
  - Clients must supply headers `x-llm-source`, `x-llm-user`, `x-llm-request-type`, and optional `x-request-id` with every API call (see `docs/audit/AUDIT-PIPELINE.md`).  
  - API Gateway access/execution logs land in CloudWatch `/aws/apigateway/central-llm-rest-api/prod` and feed the asynchronous audit stream.  
  - DynamoDB table `CentralLLMAudit` + optional S3 bucket `central-llm-audit-raw` retain per-request records for compliance.  
  Purpose: provide end-to-end traceability without impacting request latency.

- **CloudWatch Logs & Dashboard**  
  - Access logs: `/aws/apigateway/central-llm-rest-api/prod`.  
  - Delete legacy log group `/aws/apigwv2/central-llm-http-api` once IAM permissions (`logs:DeleteLogGroup`) allow—it is no longer used.  
  - Dashboard `central-llm-ops` surfaces latency, 4xx/5xx, and volume metrics.  
  Purpose: observability for request health.  
  *Note:* Metric filter for LLM error counts currently blocked by IAM (lack of `logs:PutMetricFilter`). Grant permission if needed.

- **Snapshots**  
  `snap-04d5095fae1bfaca0` retained as source-of-truth for AMI rebuilds. Purpose: fast refresh when image updates.

---

## Architecture Diagram

```
Client
  |
  | HTTPS (API key)
  v
AWS API Gateway (REST, stage prod)
  |  (VPC Link xvbo5t)
  v
Network Load Balancer central-llm-nlb (internal)
  |
  | TCP 8000
  v
EC2 g6e.2xlarge (ECS container instance)
  |
  | ECS task: vLLM container (port 8000)
  v
GPU-hosted model

Observability:
  - API Gateway access/execution logs → CloudWatch `/aws/apigateway/central-llm-rest-api/prod`
  - ECS/vLLM logs → CloudWatch `/ecs/central-llm-service`
```

---

## Launch Checklist

1. **Confirm Pricing**  
   Verify current on-demand rate for `g6e.2xlarge` in `eu-central-1` and NLB/API Gateway charges (pricing API access required).

2. **Start the GPU Host**  
   ```bash
   aws ec2 run-instances \
     --region eu-central-1 \
     --launch-template LaunchTemplateName=central-llm-launch-template \
     --count 1
   ```

3. **Register Instance with ECS**  
   ```bash
   aws ecs update-service \
     --cluster central-llm-service-cluster \
     --service central-llm-service \
     --desired-count 1 \
     --region eu-central-1
   ```

4. **Wait for Healthy Task & Target Registration**  
   ```bash
   aws ecs describe-services \
     --cluster central-llm-service-cluster \
     --services central-llm-service \
     --region eu-central-1 \
     --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}'
   ```
   Proceed when `Running: 1`. Also confirm the NLB target group shows that instance as `healthy`.

5. **Verify API**  
   Log into the usage plan:  
   - Endpoint: `https://b3yr01g4hh.execute-api.eu-central-1.amazonaws.com/prod/v1/chat/completions`  
   - Headers: `x-api-key: <central-llm-client value>` (see API Gateway console or CLI)  
   - Body: standard OpenAI-style payload.

6. **Review CloudWatch**  
   - Access logs populate `/aws/apigateway/central-llm-rest-api/prod`.  
   - Dashboard `central-llm-ops` should show traffic metrics once requests flow.

---

## Shutdown Checklist

1. **Scale ECS Task Down**
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

2. **Terminate the GPU Instance**
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:Name,Values=central-llm-ec2" "Name=instance-state-name,Values=running" \
     --region eu-central-1 \
     --query 'Reservations[*].Instances[*].InstanceId' \
     --output text | xargs -r aws ec2 terminate-instances --region eu-central-1 --instance-ids
   ```
   Instances launched via the template remove their 100 GB gp3 volume automatically.

3. **Confirm Zero Running Resources**
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

## Maintenance Tasks

- **Rotate API Keys**  
  ```bash
  aws apigateway update-api-key \
    --api-key j58bkzxvtl \
    --patch-operations op=replace,path=/value,value=<new-key> \
    --region eu-central-1
  ```

- **Refresh AMI/Snapshot**  
  Follow `docs/SNAPSHOT-AMI-LAUNCH-TEMPLATE.md` after updating the Docker image.

- **Tighten SSH Access**  
  Replace `0.0.0.0/0` for port 22 with specific administrator IP CIDRs.

- **Enable LLM Error Metrics (requires IAM change)**  
  Grant `logs:PutMetricFilter` to your IAM user/role, then create metric filters to surface model error counts or warning rates in CloudWatch.

---

## Reference IDs

- VPC: `vpc-0f01f0b70aa75657b`
- Subnets: `subnet-07b4b1c7bd77a628d`, `subnet-09f116bb3ca0b1748`, `subnet-0b8a26869769bfb4c`
- Security Groups:  
  - ECS tasks: `sg-01348191cf1b4bc37`  
  - API Gateway link: `sg-0ee960237203b60e9`
- NLB: `central-llm-nlb` (ARN `arn:aws:elasticloadbalancing:eu-central-1:396360117331:loadbalancer/net/central-llm-nlb/9ee1ea123d16308e`)
- REST API ID: `b3yr01g4hh`
- VPC Link: REST API `xvbo5t`
- Usage Plan ID: `flyode`
- API Key ID: `j58bkzxvtl`
- Snapshot ID: `snap-04d5095fae1bfaca0`

Keep this document updated as infrastructure evolves (e.g., additional availability zones, WAF, logging destinations).


