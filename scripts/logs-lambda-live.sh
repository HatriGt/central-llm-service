#!/bin/bash

set -euo pipefail

LOG_GROUP="${LOG_GROUP:-/aws/lambda/llm-audit-ingest}"
REGION="${REGION:-eu-central-1}"
SINCE="${SINCE:-5m}"

echo ">>> Tailing ${LOG_GROUP} (region ${REGION}, since ${SINCE})"
aws logs tail "${LOG_GROUP}" \
  --region "${REGION}" \
  --since "${SINCE}" \
  --follow

