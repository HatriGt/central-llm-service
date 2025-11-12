#!/bin/bash

set -euo pipefail

REGION="${REGION:-eu-central-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.2xlarge}"
CLUSTER="${CLUSTER:-central-llm-service-cluster}"
SERVICE="${SERVICE:-central-llm-service}"
TARGET_GROUP_ARN="${TARGET_GROUP_ARN:-arn:aws:elasticloadbalancing:eu-central-1:396360117331:targetgroup/central-llm-nlb-tg/fc30fe5065ab908e}"
PORT="${PORT:-8000}"
SUBNET_ID="${SUBNET_ID:-subnet-07b4b1c7bd77a628d}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-01348191cf1b4bc37}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-ecsInstanceRole}"
KEY_NAME="${KEY_NAME:-central-llm-key}"
INSTANCE_NAME="${INSTANCE_NAME:-central-llm-ec2}"
ROOT_VOLUME_SIZE="${ROOT_VOLUME_SIZE:-100}"
ROOT_VOLUME_TYPE="${ROOT_VOLUME_TYPE:-gp3}"
AMI_SSM_PARAM="${AMI_SSM_PARAM:-/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id}"

START_TS=$(date +%s)

echo ">>> Resolving latest ECS GPU-optimized AMI via ${AMI_SSM_PARAM} in ${REGION}"
if [[ -n "${AMI_ID:-}" ]]; then
  IMAGE_ID="${AMI_ID}"
  echo ">>> Using AMI_ID override: ${IMAGE_ID}"
else
  IMAGE_ID="$(
    aws ssm get-parameter \
      --region "${REGION}" \
      --name "${AMI_SSM_PARAM}" \
      --query 'Parameter.Value' \
      --output text
  )"
  if [[ -z "${IMAGE_ID}" || "${IMAGE_ID}" == "None" ]]; then
    echo "ERROR: Failed to resolve AMI ID from ${AMI_SSM_PARAM}" >&2
    exit 1
  fi
  echo ">>> Resolved AMI ID: ${IMAGE_ID}"
fi

USER_DATA_CONTENT=$(cat <<EOF
#!/bin/bash
echo ECS_CLUSTER=${CLUSTER} >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
EOF
)

USER_DATA_B64="$(printf '%s' "${USER_DATA_CONTENT}" | base64 | tr -d '\n')"

echo ">>> Starting GPU host from AMI ${IMAGE_ID} in ${REGION}"
INSTANCE_ID="$(
  aws ec2 run-instances \
    --region "${REGION}" \
    --image-id "${IMAGE_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SECURITY_GROUP_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --count 1 \
    --user-data "${USER_DATA_B64}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${ROOT_VOLUME_SIZE},VolumeType=${ROOT_VOLUME_TYPE},DeleteOnTermination=true}" \
    --query 'Instances[0].InstanceId' \
    --output text
)"

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: Failed to launch instance." >&2
  exit 1
fi

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

SERVICE_STABLE_TIMEOUT="${SERVICE_STABLE_TIMEOUT:-3600}"
SERVICE_STABLE_INTERVAL="${SERVICE_STABLE_INTERVAL:-15}"

echo ">>> Waiting for ECS service to reach steady state (timeout ${SERVICE_STABLE_TIMEOUT}s)"
SERVICE_READY_TS=${INSTANCE_READY_TS}
SERVICE_ELAPSED=0
while (( SERVICE_ELAPSED < SERVICE_STABLE_TIMEOUT )); do
  read -r RUNNING_COUNT PENDING_COUNT DESIRED_COUNT ROLLOUT_STATE FAILED_TASKS <<<"$(
    aws ecs describe-services \
      --region "${REGION}" \
      --cluster "${CLUSTER}" \
      --services "${SERVICE}" \
      --query 'services[0].{running:runningCount,pending:pendingCount,desired:desiredCount,rolloutState:deployments[0].rolloutState,failed:deployments[0].failedTasks}' \
      --output text
  )"

  if [[ "${RUNNING_COUNT}" == "${DESIRED_COUNT}" && "${PENDING_COUNT}" == "0" && "${ROLLOUT_STATE}" == "COMPLETED" ]]; then
    # Check if tasks are actually healthy (not just running)
    TASK_ARNS="$(
      aws ecs list-tasks \
        --region "${REGION}" \
        --cluster "${CLUSTER}" \
        --service-name "${SERVICE}" \
        --desired-status RUNNING \
        --query 'taskArns' \
        --output text 2>/dev/null || echo ""
    )"
    
    HEALTHY_COUNT=0
    if [[ -n "${TASK_ARNS}" && "${TASK_ARNS}" != "None" ]]; then
      for TASK_ARN in ${TASK_ARNS}; do
        TASK_HEALTH="$(
          aws ecs describe-tasks \
            --region "${REGION}" \
            --cluster "${CLUSTER}" \
            --tasks "${TASK_ARN}" \
            --query 'tasks[0].healthStatus' \
            --output text 2>/dev/null || echo "UNKNOWN"
        )"
        if [[ "${TASK_HEALTH}" == "HEALTHY" ]]; then
          HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        fi
      done
    fi
    
    if [[ "${HEALTHY_COUNT}" == "${DESIRED_COUNT}" ]]; then
      SERVICE_READY_TS=$(date +%s)
      echo ">>> ECS service reached steady state (running=${RUNNING_COUNT}, healthy=${HEALTHY_COUNT}, desired=${DESIRED_COUNT})"
      break
    else
      echo ">>> ECS service tasks running but not all healthy yet (running=${RUNNING_COUNT}, healthy=${HEALTHY_COUNT}, desired=${DESIRED_COUNT})"
    fi
  fi

  if [[ "${FAILED_TASKS}" != "0" && "${FAILED_TASKS}" != "None" ]]; then
    echo "WARNING: Detected ${FAILED_TASKS} failed tasks while waiting for steady state." >&2
  fi

  sleep "${SERVICE_STABLE_INTERVAL}"
  SERVICE_ELAPSED=$(( $(date +%s) - INSTANCE_READY_TS ))
done

if (( SERVICE_ELAPSED >= SERVICE_STABLE_TIMEOUT )); then
  echo "ERROR: ECS service did not reach steady state within ${SERVICE_STABLE_TIMEOUT}s." >&2
  echo "Last service event:"
  aws ecs describe-services \
    --region "${REGION}" \
    --cluster "${CLUSTER}" \
    --services "${SERVICE}" \
    --query 'services[0].events[0].message' \
    --output text >&2
  exit 255
fi

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


