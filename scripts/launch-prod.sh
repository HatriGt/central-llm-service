#!/bin/bash

set -euo pipefail

REGION="${REGION:-eu-central-1}"
LAUNCH_TEMPLATE="${LAUNCH_TEMPLATE:-central-llm-launch-template}"
CLUSTER="${CLUSTER:-central-llm-service-cluster}"
SERVICE="${SERVICE:-central-llm-service}"
TARGET_GROUP_ARN="${TARGET_GROUP_ARN:-arn:aws:elasticloadbalancing:eu-central-1:396360117331:targetgroup/central-llm-nlb-tg/fc30fe5065ab908e}"
PORT="${PORT:-8000}"

START_TS=$(date +%s)

echo ">>> Starting GPU host from launch template ${LAUNCH_TEMPLATE} in ${REGION}"
INSTANCE_ID="$(
  aws ec2 run-instances \
    --region "${REGION}" \
    --launch-template "LaunchTemplateName=${LAUNCH_TEMPLATE}" \
    --count 1 \
    --query 'Instances[0].InstanceId' \
    --output text
)"

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: Failed to launch instance." >&2
  exit 1
fi

INSTANCE_LAUNCH_TS=$(date +%s)

echo ">>> Launched instance ${INSTANCE_ID}; waiting for instance status OK"
aws ec2 wait instance-status-ok \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}"

INSTANCE_READY_TS=$(date +%s)
echo ">>> Instance status OK after $((INSTANCE_READY_TS - START_TS))s"

echo ">>> Registering ${INSTANCE_ID} with target group"
aws elbv2 register-targets \
  --region "${REGION}" \
  --target-group-arn "${TARGET_GROUP_ARN}" \
  --targets "Id=${INSTANCE_ID},Port=${PORT}"

echo ">>> Scaling ECS service ${SERVICE} to desired count 1"
aws ecs update-service \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --desired-count 1 >/dev/null

echo ">>> Waiting for ECS service to reach steady state"
aws ecs wait services-stable \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}"

SERVICE_READY_TS=$(date +%s)
echo ">>> ECS service reports steady state after $((SERVICE_READY_TS - INSTANCE_READY_TS))s (cumulative $((SERVICE_READY_TS - START_TS))s)"

TARGET_HEALTH_TIMEOUT="${TARGET_HEALTH_TIMEOUT:-1800}"
TARGET_HEALTH_INTERVAL="${TARGET_HEALTH_INTERVAL:-30}"

echo ">>> Waiting for NLB target to be in-service (timeout ${TARGET_HEALTH_TIMEOUT}s)"
TARGET_READY_TS=$SERVICE_READY_TS
ELAPSED=0
while (( ELAPSED < TARGET_HEALTH_TIMEOUT )); do
  HEALTH_STATE="$(
    aws elbv2 describe-target-health \
      --region "${REGION}" \
      --target-group-arn "${TARGET_GROUP_ARN}" \
      --targets "Id=${INSTANCE_ID},Port=${PORT}" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' \
      --output text
  )"
  if [[ "${HEALTH_STATE}" == "healthy" ]]; then
    TARGET_READY_TS=$(date +%s)
    break
  fi
  sleep "${TARGET_HEALTH_INTERVAL}"
  ELAPSED=$(( $(date +%s) - SERVICE_READY_TS ))
done

if (( ELAPSED >= TARGET_HEALTH_TIMEOUT )); then
  echo "ERROR: Target ${INSTANCE_ID} did not become healthy within ${TARGET_HEALTH_TIMEOUT}s." >&2
  exit 255
fi

echo ">>> NLB target healthy after $((TARGET_READY_TS - SERVICE_READY_TS))s (cumulative $((TARGET_READY_TS - START_TS))s)"

TOTAL_END_TS=${TARGET_READY_TS}

if [[ -n "${API_GATEWAY_URL:-}" ]]; then
  if [[ -z "${API_GATEWAY_KEY:-}" ]]; then
    echo "WARNING: API_GATEWAY_KEY not set; skipping API availability timing." >&2
  else
    echo ">>> Probing API Gateway endpoint ${API_GATEWAY_URL}"
    API_PROBE_START=$(date +%s)
    ATTEMPT=0
    while true; do
      ATTEMPT=$((ATTEMPT + 1))
      set +e
      HTTP_STATUS=$(curl -sS -o /dev/null \
        -w "%{http_code}" \
        -H "x-api-key: ${API_GATEWAY_KEY}" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        "${API_GATEWAY_URL}")
      CURL_EXIT=$?
      set -e
      if [[ "${CURL_EXIT}" -eq 0 && "${HTTP_STATUS}" == "200" ]]; then
        break
      fi
      sleep 5
    done
    API_READY_TS=$(date +%s)
    TOTAL_END_TS=${API_READY_TS}
    echo ">>> API Gateway returned 200 after $((API_READY_TS - API_PROBE_START))s (cumulative $((API_READY_TS - START_TS))s, attempts: ${ATTEMPT})"
  fi
fi

echo ">>> central-llm service is live. Instance ${INSTANCE_ID} is healthy behind API Gateway."
echo ">>> Total bring-up time: $((TOTAL_END_TS - START_TS))s"

