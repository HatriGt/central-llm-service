#!/bin/bash

set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER="${CLUSTER:-central-llm-service-cluster}"
SERVICE="${SERVICE:-central-llm-service}"
TARGET_GROUP_ARN="${TARGET_GROUP_ARN:-arn:aws:elasticloadbalancing:eu-central-1:396360117331:targetgroup/central-llm-nlb-tg/fc30fe5065ab908e}"
PORT="${PORT:-8000}"

echo ">>> Scaling ECS service ${SERVICE} down to 0"
aws ecs update-service \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --desired-count 0 >/dev/null

echo ">>> Waiting for ECS service to drain"
aws ecs wait services-stable \
  --region "${REGION}" \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}"

echo ">>> Listing active container instances in cluster ${CLUSTER}"
CONTAINER_ARNS="$(
  aws ecs list-container-instances \
    --region "${REGION}" \
    --cluster "${CLUSTER}" \
    --status ACTIVE \
    --query 'containerInstanceArns' \
    --output text
)"

if [[ -z "${CONTAINER_ARNS}" || "${CONTAINER_ARNS}" == "None" ]]; then
  echo ">>> No running instances found. Shutdown complete."
  exit 0
fi

read -r -a CONTAINER_ARRAY <<<"${CONTAINER_ARNS}"

INSTANCE_IDS=""
for CONTAINER_ARN in "${CONTAINER_ARRAY[@]}"; do
  INFO="$(
    aws ecs describe-container-instances \
      --region "${REGION}" \
      --cluster "${CLUSTER}" \
      --container-instances "${CONTAINER_ARN}" \
      --query 'containerInstances[0].{id:ec2InstanceId,status:status}' \
      --output text
  )"
  EC2_ID=$(cut -f1 <<<"${INFO}")
  STATUS=$(cut -f2 <<<"${INFO}")

  if [[ "${STATUS}" != "ACTIVE" && "${STATUS}" != "DRAINING" ]]; then
    continue
  fi

  echo ">>> Deregistering target ${EC2_ID} from load balancer"
  aws elbv2 deregister-targets \
    --region "${REGION}" \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --targets "Id=${EC2_ID},Port=${PORT}" || true

  echo ">>> Draining container instance ${CONTAINER_ARN}"
  aws ecs update-container-instances-state \
    --region "${REGION}" \
    --cluster "${CLUSTER}" \
    --container-instances "${CONTAINER_ARN}" \
    --status DRAINING >/dev/null

  INSTANCE_IDS="${INSTANCE_IDS} ${EC2_ID}"

  echo ">>> Deregistering container instance ${CONTAINER_ARN}"
  aws ecs deregister-container-instance \
    --region "${REGION}" \
    --cluster "${CLUSTER}" \
    --container-instance "${CONTAINER_ARN}" \
    --force >/dev/null
done

INSTANCE_IDS=$(echo "${INSTANCE_IDS}" | xargs)

if [[ -n "${INSTANCE_IDS}" ]]; then
  echo ">>> Terminating EC2 instances:${INSTANCE_IDS}"
  aws ec2 terminate-instances \
    --region "${REGION}" \
    --instance-ids ${INSTANCE_IDS} >/dev/null

  echo ">>> Waiting for termination to finish"
  aws ec2 wait instance-terminated \
    --region "${REGION}" \
    --instance-ids ${INSTANCE_IDS}
else
  echo ">>> No EC2 instances required termination."
fi

echo ">>> Shutdown complete. ECS cluster has no active hosts."
