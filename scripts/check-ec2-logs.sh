#!/bin/bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DIR}/.." && pwd)"

CLUSTER="${CLUSTER:-central-llm-service-cluster}"
SERVICE="${SERVICE:-central-llm-service}"
REGION="${REGION:-eu-central-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/central-llm-key.pem}"
INSTANCE_ID="${INSTANCE_ID:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LINES="${LINES:-100}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [LOG_TYPE]

Check logs on the ECS EC2 instance via SSH.

LOG_TYPE options:
  docker          - Docker daemon logs (default)
  ecs-agent       - ECS agent logs
  containers      - List all Docker containers
  images          - List all Docker images
  disk            - Disk usage and Docker disk usage
  pull            - Monitor Docker image pull activity
  task            - Check ECS task status and events
  all             - Show all log types (docker, ecs-agent, containers, disk)

OPTIONS:
  --instance-id ID    - Use specific EC2 instance ID
  --public-ip IP      - Use specific public IP address
  --lines COUNT       - Number of lines to show (default: ${LINES})
  --follow            - Follow logs (tail -f)
  --since TIME        - Show logs since TIME (e.g., "10 minutes ago", "1 hour ago")
  --grep PATTERN      - Filter logs with grep pattern
  -h, --help          - Show this help message

Environment overrides:
  CLUSTER       (default: ${CLUSTER})
  SERVICE       (default: ${SERVICE})
  REGION        (default: ${REGION})
  SSH_KEY_PATH  (default: ${SSH_KEY_PATH})
  INSTANCE_ID   - EC2 instance ID (auto-detected if not set)
  PUBLIC_IP     - EC2 public IP (auto-detected if not set)

Examples:
  # Check Docker logs
  $0 docker

  # Follow ECS agent logs
  $0 ecs-agent --follow

  # Check disk usage
  $0 disk

  # Monitor image pull activity
  $0 pull --since "5 minutes ago"

  # Check Docker logs with grep filter
  $0 docker --grep "llama31"

  # Show all information
  $0 all
EOF
}

LOG_TYPE="docker"
FOLLOW=0
SINCE=""
GREP_PATTERN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    docker|ecs-agent|containers|images|disk|pull|task|all)
      LOG_TYPE="$1"
      shift
      ;;
    --instance-id)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="$2"
      shift 2
      ;;
    --lines)
      LINES="$2"
      shift 2
      ;;
    --follow)
      FOLLOW=1
      shift
      ;;
    --since)
      SINCE="$2"
      shift 2
      ;;
    --grep)
      GREP_PATTERN="$2"
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
  echo "ERROR: SSH key not found at ${SSH_KEY_PATH}" >&2
  echo "Set SSH_KEY_PATH to the correct key path." >&2
  exit 1
fi

# Resolve instance ID and public IP if not provided
if [[ -z "${INSTANCE_ID}" ]] || [[ -z "${PUBLIC_IP}" ]]; then
  echo ">>> Resolving EC2 instance for service ${SERVICE}..."
  
  TASK_ARN="$(
    aws ecs list-tasks \
      --cluster "${CLUSTER}" \
      --service-name "${SERVICE}" \
      --region "${REGION}" \
      --query 'taskArns[0]' \
      --output text 2>/dev/null || echo "None"
  )"

  if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
    # Try to get any instance in the cluster
    echo ">>> No tasks found, trying to get any container instance..."
    CONTAINER_INSTANCE_ARN="$(
      aws ecs list-container-instances \
        --cluster "${CLUSTER}" \
        --region "${REGION}" \
        --query 'containerInstanceArns[0]' \
        --output text 2>/dev/null || echo "None"
    )"
    
    if [[ -z "${CONTAINER_INSTANCE_ARN}" || "${CONTAINER_INSTANCE_ARN}" == "None" ]]; then
      echo "ERROR: No container instances found in cluster ${CLUSTER}" >&2
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
  else
    CONTAINER_INSTANCE_ARN="$(
      aws ecs describe-tasks \
        --cluster "${CLUSTER}" \
        --tasks "${TASK_ARN}" \
        --region "${REGION}" \
        --query 'tasks[0].containerInstanceArn' \
        --output text
    )"
    
    INSTANCE_ID="$(
      aws ecs describe-container-instances \
        --cluster "${CLUSTER}" \
        --container-instances "${CONTAINER_INSTANCE_ARN}" \
        --region "${REGION}" \
        --query 'containerInstances[0].ec2InstanceId' \
        --output text
    )"
  fi

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    echo "ERROR: Unable to resolve EC2 instance ID" >&2
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
    echo "ERROR: EC2 instance ${INSTANCE_ID} does not have a public IP address" >&2
    exit 1
  fi
fi

echo ">>> Connecting to ${INSTANCE_ID} (${PUBLIC_IP})"
echo ""

# SSH command builder
ssh_cmd() {
  local cmd="$1"
  ssh -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "ec2-user@${PUBLIC_IP}" \
    "$cmd"
}

# Build journalctl command with filters
build_journalctl_cmd() {
  local unit="$1"
  local cmd="sudo journalctl -u ${unit}"
  
  if [[ -n "${SINCE}" ]]; then
    cmd="${cmd} --since \"${SINCE}\""
  else
    cmd="${cmd} -n ${LINES}"
  fi
  
  if [[ "${FOLLOW}" -eq 1 ]]; then
    cmd="${cmd} -f"
  else
    cmd="${cmd} --no-pager"
  fi
  
  if [[ -n "${GREP_PATTERN}" ]]; then
    cmd="${cmd} | grep -i \"${GREP_PATTERN}\""
  fi
  
  echo "${cmd}"
}

case "${LOG_TYPE}" in
  docker)
    echo ">>> Docker daemon logs"
    echo "---"
    cmd=$(build_journalctl_cmd "docker")
    ssh_cmd "${cmd}"
    ;;
    
  ecs-agent)
    echo ">>> ECS agent logs"
    echo "---"
    if [[ -n "${SINCE}" ]]; then
      cmd="sudo tail -n ${LINES} /var/log/ecs/ecs-agent.log | grep -A 1000 \"$(date -d \"${SINCE}\" -u +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo '')\""
    else
      cmd="sudo tail -n ${LINES} /var/log/ecs/ecs-agent.log"
    fi
    if [[ "${FOLLOW}" -eq 1 ]]; then
      cmd="sudo tail -f /var/log/ecs/ecs-agent.log"
    fi
    if [[ -n "${GREP_PATTERN}" ]]; then
      cmd="${cmd} | grep -i \"${GREP_PATTERN}\""
    fi
    ssh_cmd "${cmd}"
    ;;
    
  containers)
    echo ">>> Docker containers"
    echo "---"
    ssh_cmd "sudo docker ps -a"
    ;;
    
  images)
    echo ">>> Docker images"
    echo "---"
    ssh_cmd "sudo docker images"
    ;;
    
  disk)
    echo ">>> Disk usage"
    echo "---"
    ssh_cmd "df -h / && echo '' && echo '>>> Docker disk usage:' && sudo docker system df"
    ;;
    
  pull)
    echo ">>> Docker image pull activity"
    echo "---"
    since="${SINCE:-10 minutes ago}"
    ssh_cmd "sudo journalctl -u docker --since \"${since}\" --no-pager | grep -i -E 'pull|Pulling|Downloading|Extracting|llama|image|layer' | tail -${LINES}"
    ;;
    
  task)
    echo ">>> ECS task status"
    echo "---"
    TASK_ARN="$(
      aws ecs list-tasks \
        --cluster "${CLUSTER}" \
        --service-name "${SERVICE}" \
        --region "${REGION}" \
        --query 'taskArns[0]' \
        --output text 2>/dev/null || echo "None"
    )"
    if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
      echo "No tasks found for service ${SERVICE}"
    else
      TASK_ID=$(echo "${TASK_ARN}" | awk -F'/' '{print $NF}')
      echo "Task ID: ${TASK_ID}"
      aws ecs describe-tasks \
        --cluster "${CLUSTER}" \
        --tasks "${TASK_ARN}" \
        --region "${REGION}" \
        --query 'tasks[0].{lastStatus:lastStatus,desiredStatus:desiredStatus,containers:containers[0].{name:name,lastStatus:lastStatus,reason:reason}}' \
        --output json
    fi
    ;;
    
  all)
    echo ">>> === Docker Containers ==="
    ssh_cmd "sudo docker ps -a"
    echo ""
    echo ">>> === Docker Images ==="
    ssh_cmd "sudo docker images"
    echo ""
    echo ">>> === Disk Usage ==="
    ssh_cmd "df -h / && echo '' && sudo docker system df"
    echo ""
    echo ">>> === Recent Docker Logs ==="
    cmd=$(build_journalctl_cmd "docker")
    ssh_cmd "${cmd}" | tail -${LINES}
    echo ""
    echo ">>> === Recent ECS Agent Logs ==="
    ssh_cmd "sudo tail -n ${LINES} /var/log/ecs/ecs-agent.log"
    ;;
    
  *)
    echo "ERROR: Unknown log type: ${LOG_TYPE}" >&2
    usage
    exit 1
    ;;
esac

