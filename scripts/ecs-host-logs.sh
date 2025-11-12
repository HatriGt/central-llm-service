#!/bin/bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DIR}/.." && pwd)"

CLUSTER="${CLUSTER:-central-llm-service-cluster}"
SERVICE="${SERVICE:-central-llm-service}"
REGION="${REGION:-eu-central-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/central-llm-key.pem}"
LOG_FILE="${LOG_FILE:-/var/log/ecs/ecs-agent.log}"
LINES="${LINES:-200}"
FOLLOW=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--follow] [--log-file PATH] [--lines COUNT]

Tails a log file on the ECS container host backing the ${SERVICE} service.

Environment overrides:
  CLUSTER       (default: ${CLUSTER})
  SERVICE       (default: ${SERVICE})
  REGION        (default: ${REGION})
  SSH_KEY_PATH  (default: ${SSH_KEY_PATH})
  LOG_FILE      (default: ${LOG_FILE})
  LINES         (default: ${LINES})

Examples:
  ${SSH_KEY_PATH:+SSH_KEY_PATH="${SSH_KEY_PATH}" }$0
  LOG_FILE=/var/log/messages $0 --lines 500
  $0 --follow
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow)
      FOLLOW=1
      shift
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --lines)
      LINES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "SSH key not found at ${SSH_KEY_PATH}. Set SSH_KEY_PATH to the correct key." >&2
  exit 1
fi

TASK_ARN="${TASK_ARN:-$(
  aws ecs list-tasks \
    --cluster "${CLUSTER}" \
    --service-name "${SERVICE}" \
    --desired-status RUNNING \
    --region "${REGION}" \
    --query 'taskArns[0]' \
    --output text
)}"

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
  echo "No running tasks found for service ${SERVICE} in cluster ${CLUSTER} (region ${REGION})." >&2
  exit 1
fi

CONTAINER_INSTANCE_ARN="$(
  aws ecs describe-tasks \
    --cluster "${CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --region "${REGION}" \
    --query 'tasks[0].containerInstanceArn' \
    --output text
)"

if [[ -z "${CONTAINER_INSTANCE_ARN}" || "${CONTAINER_INSTANCE_ARN}" == "None" ]]; then
  echo "Unable to resolve container instance for task ${TASK_ARN}." >&2
  exit 1
fi

INSTANCE_ID="$(
  aws ecs describe-container-instances \
    --cluster "${CLUSTER}" \
    --container-instances "${CONTAINER_INSTANCE_ARN}" \
    --region "${REGION}" \
    --query 'containerInstances[0].ec2InstanceId' \
    --output text
)"

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "Unable to resolve EC2 instance for container instance ${CONTAINER_INSTANCE_ARN}." >&2
  exit 1
fi

PUBLIC_IP="$(
  aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
)"

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "None" ]]; then
  echo "EC2 instance ${INSTANCE_ID} does not have a public IP address." >&2
  exit 1
fi

TAIL_ARGS=("-n" "${LINES}")
if [[ "${FOLLOW}" -eq 1 ]]; then
  TAIL_ARGS+=("-f")
fi

echo ">>> SSH to ${INSTANCE_ID} (${PUBLIC_IP}) to tail ${LOG_FILE}"
ssh -i "${SSH_KEY_PATH}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "ec2-user@${PUBLIC_IP}" \
  "sudo tail ${TAIL_ARGS[*]} ${LOG_FILE}"

