#!/bin/bash

set -euo pipefail

REGION="${REGION:-eu-central-1}"
SINCE="${SINCE:-5m}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [ecs|apigw|apigw-exec] [--follow]

  ecs         Tail the ECS/vLLM container logs (/ecs/central-llm-service)
  apigw       Tail API Gateway access logs (/aws/apigateway/central-llm-rest-api/prod)
  apigw-exec  Tail API Gateway execution logs (API-Gateway-Execution-Logs_b3yr01g4hh/prod)

Environment overrides:
  REGION (default: ${REGION})
  SINCE  (default: ${SINCE})

Pass --follow to stream continuously.

Default stream is 'ecs' when no argument is supplied.
EOF
}

STREAM="${1:-ecs}"
if [[ $# -gt 0 ]]; then
  shift
fi

FOLLOW=""
for arg in "$@"; do
  if [[ "${arg}" == "--follow" ]]; then
    FOLLOW="--follow"
  else
    echo "Unknown argument: ${arg}" >&2
    usage
    exit 1
  fi
done

case "${STREAM}" in
  ecs)
    LOG_GROUP="/ecs/central-llm-service"
    ;;
  apigw)
    LOG_GROUP="/aws/apigateway/central-llm-rest-api/prod"
    ;;
  apigw-exec)
    LOG_GROUP="API-Gateway-Execution-Logs_b3yr01g4hh/prod"
    ;;
  *)
    echo "Unknown stream: ${STREAM}" >&2
    usage
    exit 1
    ;;
esac

echo ">>> Tailing ${LOG_GROUP} (region ${REGION}, since ${SINCE})"
aws logs tail "${LOG_GROUP}" \
  --region "${REGION}" \
  --since "${SINCE}" \
  ${FOLLOW:+${FOLLOW}}

